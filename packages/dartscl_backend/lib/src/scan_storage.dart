import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

/// Logger for [ScanStorage].
final Logger _log = Logger('ScanStorage');

/// Policy applied when the configured storage limit would be exceeded.
enum StorageFullPolicy {
  /// Delete the oldest files until the new file fits.
  evictOldest,

  /// Refuse to store the new file (the scan request fails).
  error,
}

/// Thrown when a new scan cannot be stored because the storage limit is
/// reached and [StorageFullPolicy.error] is active.
class StorageFullException implements Exception {
  final int neededBytes;
  final int maxBytes;

  StorageFullException(this.neededBytes, this.maxBytes);

  @override
  String toString() =>
      'Storage full: need $neededBytes bytes, limit is $maxBytes bytes';
}

/// Persistent storage for scanned files with a metadata index.
///
/// Files are stored as `<id>.<extension>` inside [baseDir]; a `scans.json`
/// index file holds one [ScannedFile] metadata record per file. The class
/// enforces two retention rules:
///  1. files older than [retentionDays] are deleted (checked on load and on
///     every save),
///  2. total size is kept below [maxStorageBytes] — either by evicting the
///     oldest files or by throwing [StorageFullException], depending on
///     [fullPolicy].
class ScanStorage {
  final Directory baseDir;
  final int maxStorageBytes;
  final StorageFullPolicy fullPolicy;
  final int retentionDays;

  final Map<String, ScannedFile> _index = {};
  final Uuid _uuid = const Uuid();

  static const int _defaultMaxStorageBytes = 1024 * 1024 * 1024; // 1 GiB
  static const int _defaultRetentionDays = 365;

  ScanStorage({
    required this.baseDir,
    required this.maxStorageBytes,
    required this.fullPolicy,
    required this.retentionDays,
  }) {
    _loadIndexSync();
    _enforceRetentionSync();
  }

  /// Parses a human-readable storage size into bytes.
  ///
  /// Accepts an optional binary unit suffix (case-insensitive, with or
  /// without a trailing `B`/`iB`):
  /// - `K`/`KB` — 1024 bytes
  /// - `M`/`MB` — 1024² bytes (mebibyte)
  /// - `G`/`GB` — 1024³ bytes (gibibyte)
  /// - `T`/`TB` — 1024⁴ bytes (tebibyte)
  ///
  /// A bare number is interpreted as bytes. Returns `null` for unparseable
  /// or overflowing input.
  static int? parseStorageSize(String input) {
    final s = input.trim().toLowerCase();
    final match = RegExp(r'^(\d+)\s*([kmgt]?)(?:i?b)?$').firstMatch(s);
    if (match == null) return null;
    final value = int.tryParse(match.group(1)!);
    if (value == null) return null;
    const units = <String, int>{
      '': 1,
      'k': 1024,
      'm': 1024 * 1024,
      'g': 1024 * 1024 * 1024,
      't': 1024 * 1024 * 1024 * 1024,
    };
    final unit = units[match.group(2)!]!;
    // Guard against overflow from absurd inputs (e.g. a multi-exabyte value).
    if (value > (1 << 62) ~/ unit) return null;
    return value * unit;
  }

  /// Builds a [ScanStorage] from environment variables.
  ///
  /// Supported variables:
  /// - `SCAN_STORAGE_PATH` (default `./scans`) — directory for scan files,
  /// - `SCAN_MAX_STORAGE` (default `1GB`) — size limit, human-readable
  ///   (`512MB`, `2G`, `1073741824`) — see [parseStorageSize],
  /// - `SCAN_STORAGE_FULL_POLICY` (`evict-oldest` or `error`, default `error`),
  /// - `SCAN_RETENTION_DAYS` (default 365).
  factory ScanStorage.fromEnvironment() {
    final baseDir = Directory(
      Platform.environment['SCAN_STORAGE_PATH'] ?? './scans',
    );
    final rawSize = Platform.environment['SCAN_MAX_STORAGE'];
    final maxStorageBytes =
        (rawSize != null ? parseStorageSize(rawSize) : null) ??
            _defaultMaxStorageBytes;
    final fullPolicy =
        Platform.environment['SCAN_STORAGE_FULL_POLICY']?.toLowerCase() ==
                'evict-oldest'
            ? StorageFullPolicy.evictOldest
            : StorageFullPolicy.error;
    final retentionDays = int.tryParse(
          Platform.environment['SCAN_RETENTION_DAYS'] ?? '',
        ) ??
        _defaultRetentionDays;
    return ScanStorage(
      baseDir: baseDir,
      maxStorageBytes: maxStorageBytes,
      fullPolicy: fullPolicy,
      retentionDays: retentionDays,
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns all stored files, most recently modified first.
  List<ScannedFile> list() {
    final files = _index.values.toList()
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return files;
  }

  /// Returns metadata for a single file, or `null` if unknown.
  ScannedFile? get(String id) => _index[id];

  /// Absolute path of a stored file. Used by the PDF pipeline to merge.
  String pathFor(String id) => _filePath(id, _index[id]?.mimeType);

  /// Reads a stored file's bytes. Throws [FileSystemException] if missing.
  Future<Uint8List> readBytes(String id) async {
    return File(pathFor(id)).readAsBytes();
  }

  /// Stores scanned bytes as a new file, or replaces an existing file when
  /// [id] is provided (append to an existing PDF).
  ///
  /// Returns the metadata record (with a fresh id if none was given). Enforces
  /// retention and the storage limit before writing.
  Future<ScannedFile> save(
    Uint8List bytes, {
    required String mimeType,
    String? id,
  }) async {
    await baseDir.create(recursive: true);
    _enforceRetentionSync();

    final now = DateTime.now();
    final isNew = id == null;
    final fileId = id ?? _uuid.v4();
    final existing = _index[fileId];

    // Determine what the new total size would be before writing.
    final incomingDelta = bytes.length - (existing?.sizeBytes ?? 0);
    if (incomingDelta > 0) {
      _enforceLimitSync(incomingDelta);
    }

    final name = existing?.name ?? _defaultName(now, mimeType);
    final path = _filePath(fileId, mimeType);
    await File(path).writeAsBytes(bytes);

    final record = ScannedFile(
      id: fileId,
      name: name,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      createdAt: existing?.createdAt ?? now,
      modifiedAt: now,
    );
    _index[fileId] = record;
    await _persistIndex();

    _log.info(
      'Stored scan $fileId ("$name", ${bytes.length} bytes, '
      '${isNew ? 'new' : 'appended'}).',
    );
    return record;
  }

  /// Deletes a stored file and its index entry.
  ///
  /// Returns `false` if the file does not exist.
  Future<bool> delete(String id) async {
    final entry = _index[id];
    if (entry == null) return false;
    try {
      final file = File(pathFor(id));
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.warning('Failed to delete scan file $id: $e');
    }
    _index.remove(id);
    await _persistIndex();
    _log.info('Deleted scan $id ("${entry.name}").');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Retention / limit enforcement
  // ---------------------------------------------------------------------------

  /// Deletes files whose `modifiedAt` is older than [retentionDays].
  void _enforceRetentionSync() {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    final expired =
        _index.values.where((f) => f.modifiedAt.isBefore(cutoff)).toList();
    for (final file in expired) {
      _deleteFileSync(file);
      _index.remove(file.id);
    }
    if (expired.isNotEmpty) {
      _log.info('Retention: removed ${expired.length} expired scan(s).');
      _persistIndexSync();
    }
  }

  /// Ensures the storage limit can absorb [incomingBytes].
  void _enforceLimitSync(int incomingBytes) {
    var total = _index.values.fold<int>(0, (sum, f) => sum + f.sizeBytes);
    if (total + incomingBytes <= maxStorageBytes) return;

    if (fullPolicy == StorageFullPolicy.error) {
      throw StorageFullException(incomingBytes, maxStorageBytes);
    }

    // Evict oldest (by modifiedAt) until the new file fits.
    final ordered = list();
    for (final file in ordered.reversed) {
      if (total + incomingBytes <= maxStorageBytes) break;
      _deleteFileSync(file);
      _index.remove(file.id);
      total -= file.sizeBytes;
      _log.info(
        'Storage full: evicted oldest scan ${file.id} ("${file.name}").',
      );
    }
    _persistIndexSync();
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------

  File get _indexFile => File('${baseDir.path}/scans.json');

  String _filePath(String id, String? mimeType) {
    return '${baseDir.path}/$id${_extensionFor(mimeType)}';
  }

  static String _extensionFor(String? mimeType) {
    switch (mimeType) {
      case 'application/pdf':
        return '.pdf';
      case 'image/png':
        return '.png';
      case 'image/jpeg':
      default:
        return '.jpg';
    }
  }

  static String _defaultName(DateTime now, String mimeType) {
    final ext = _extensionFor(mimeType);
    String p2(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${p2(now.month)}-${p2(now.day)} '
        '${p2(now.hour)}:${p2(now.minute)}:${p2(now.second)}';
    return 'Scan $ts$ext';
  }

  void _loadIndexSync() {
    try {
      if (!baseDir.existsSync()) {
        baseDir.createSync(recursive: true);
        return;
      }
      final indexFile = _indexFile;
      if (!indexFile.existsSync()) return;
      final decoded = jsonDecode(indexFile.readAsStringSync());
      final list = (decoded as List<dynamic>)
          .map((e) => ScannedFile.fromJson(e as Map<String, dynamic>));
      for (final file in list) {
        _index[file.id] = file;
      }
      _log.info('Loaded ${_index.length} stored scan(s) from ${baseDir.path}.');
    } catch (e) {
      _log.warning('Failed to load scan index, starting empty: $e');
      _index.clear();
    }
  }

  Future<void> _persistIndex() async {
    try {
      await baseDir.create(recursive: true);
      await _indexFile.writeAsString(
        jsonEncode(_index.values.map((f) => f.toJson()).toList()),
      );
    } catch (e) {
      _log.warning('Failed to persist scan index: $e');
    }
  }

  void _persistIndexSync() {
    try {
      baseDir.createSync(recursive: true);
      _indexFile.writeAsStringSync(
        jsonEncode(_index.values.map((f) => f.toJson()).toList()),
      );
    } catch (e) {
      _log.warning('Failed to persist scan index: $e');
    }
  }

  void _deleteFileSync(ScannedFile file) {
    try {
      final f = File(_filePath(file.id, file.mimeType));
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      _log.warning('Failed to delete scan file ${file.id}: $e');
    }
  }
}
