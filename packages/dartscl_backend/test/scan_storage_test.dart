import 'dart:io';
import 'dart:typed_data';

import 'package:dartscl_backend/src/scan_storage.dart';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ScanStorage.parseStorageSize', () {
    test('parses bare byte values', () {
      expect(ScanStorage.parseStorageSize('0'), equals(0));
      expect(ScanStorage.parseStorageSize('1073741824'), equals(1073741824));
      expect(ScanStorage.parseStorageSize(' 512 '), equals(512));
    });

    test('parses unit suffixes case-insensitively', () {
      expect(ScanStorage.parseStorageSize('1kb'), equals(1024));
      expect(ScanStorage.parseStorageSize('1K'), equals(1024));
      expect(ScanStorage.parseStorageSize('1kib'), equals(1024));
      expect(ScanStorage.parseStorageSize('2MB'), equals(2 * 1024 * 1024));
      expect(
        ScanStorage.parseStorageSize('1G'),
        equals(1024 * 1024 * 1024),
      );
      expect(
        ScanStorage.parseStorageSize('1TB'),
        equals(1024 * 1024 * 1024 * 1024),
      );
    });

    test('rejects unparseable input', () {
      expect(ScanStorage.parseStorageSize('abc'), isNull);
      expect(ScanStorage.parseStorageSize('-5'), isNull);
      expect(ScanStorage.parseStorageSize('1.5MB'), isNull);
      expect(ScanStorage.parseStorageSize('1 XB'), isNull);
      expect(ScanStorage.parseStorageSize(''), isNull);
    });

    test('rejects overflowing input instead of wrapping around', () {
      // A multi-exabyte value must not silently overflow int arithmetic.
      final huge = List.filled(25, '9').join();
      expect(ScanStorage.parseStorageSize(huge), isNull);
    });
  });

  group('ScanStorage', () {
    late Directory tempDir;

    /// Creates a storage with the given limits in [tempDir].
    ScanStorage buildStorage({
      int maxBytes = 1 << 20,
      StorageFullPolicy policy = StorageFullPolicy.evictOldest,
      int retentionDays = 365,
    }) {
      return ScanStorage(
        baseDir: tempDir,
        maxStorageBytes: maxBytes,
        fullPolicy: policy,
        retentionDays: retentionDays,
      );
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('scan_storage_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('save and list return metadata; files are readable', () async {
      final storage = buildStorage();
      final record = await storage.save(
        Uint8List.fromList(List.filled(10, 42)),
        mimeType: 'application/pdf',
      );

      expect(storage.list(), hasLength(1));
      expect(record.name, startsWith('Scan '));
      expect(record.sizeBytes, equals(10));
      expect(await storage.readBytes(record.id), hasLength(10));
    });

    test('delete removes file and index entry and returns false afterwards',
        () async {
      final storage = buildStorage();
      final record = await storage.save(
        Uint8List.fromList(List.filled(4, 1)),
        mimeType: 'image/jpeg',
      );

      expect(await storage.delete(record.id), isTrue);
      expect(storage.get(record.id), isNull);
      expect(await storage.delete(record.id), isFalse);
    });

    test('evictOldest removes oldest files until the new file fits',
        () async {
      final storage = buildStorage(maxBytes: 100);

      final first = await storage.save(
        Uint8List.fromList(List.filled(40, 1)),
        mimeType: 'image/jpeg',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await storage.save(
        Uint8List.fromList(List.filled(40, 2)),
        mimeType: 'image/jpeg',
      );

      // Third save (60 bytes) cannot fit alongside both → the oldest is evicted.
      await storage.save(
        Uint8List.fromList(List.filled(60, 3)),
        mimeType: 'image/jpeg',
      );

      final ids = storage.list().map((f) => f.id).toSet();
      expect(ids.contains(first.id), isFalse);
      expect(storage.list(), hasLength(2));
    });

    test('error policy throws StorageFullException when full', () async {
      final storage = buildStorage(
        maxBytes: 50,
        policy: StorageFullPolicy.error,
      );
      await storage.save(
        Uint8List.fromList(List.filled(50, 1)),
        mimeType: 'image/jpeg',
      );

      await expectLater(
        storage.save(
          Uint8List.fromList(List.filled(10, 2)),
          mimeType: 'image/jpeg',
        ),
        throwsA(isA<StorageFullException>()),
      );
    });

    test('retention deletes files older than retentionDays', () async {
      final storage = buildStorage(retentionDays: 30);

      final record = await storage.save(
        Uint8List.fromList(List.filled(8, 7)),
        mimeType: 'image/png',
      );

      // Simulate age by backdating the on-disk index.
      final aged = ScannedFile(
        id: record.id,
        name: record.name,
        mimeType: record.mimeType,
        sizeBytes: record.sizeBytes,
        createdAt: record.createdAt.subtract(const Duration(days: 31)),
        modifiedAt: record.modifiedAt.subtract(const Duration(days: 31)),
      );
      File('${tempDir.path}/scans.json').writeAsStringSync('[${aged.toJson()}]');

      // Rebuilding the storage runs retention enforcement on load.
      final reloaded = buildStorage(retentionDays: 30);

      expect(reloaded.get(record.id), isNull);
      expect(File('${tempDir.path}/$record.id').existsSync(), isFalse);
    });

    test('index persists across instances (reload)', () async {
      final storage = buildStorage();
      final record = await storage.save(
        Uint8List.fromList(List.filled(6, 9)),
        mimeType: 'application/pdf',
      );

      final reloaded = buildStorage();
      expect(reloaded.get(record.id)?.sizeBytes, equals(6));
    });

    test('corrupt index file is tolerated and starts empty', () async {
      File('${tempDir.path}/scans.json').writeAsStringSync('{not valid json');
      final storage = buildStorage();
      expect(storage.list(), isEmpty);
      // A subsequent save must still work and persist a fresh index.
      await storage.save(
        Uint8List.fromList(List.filled(3, 1)),
        mimeType: 'image/jpeg',
      );
      expect(storage.list(), hasLength(1));
    });

    test('save with existing id keeps name and createdAt (replace)',
        () async {
      final storage = buildStorage();
      final original = await storage.save(
        Uint8List.fromList(List.filled(5, 1)),
        mimeType: 'application/pdf',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final replaced = await storage.save(
        Uint8List.fromList(List.filled(8, 2)),
        mimeType: 'application/pdf',
        id: original.id,
      );

      expect(replaced.id, equals(original.id));
      expect(replaced.name, equals(original.name));
      expect(replaced.createdAt, equals(original.createdAt));
      expect(replaced.sizeBytes, equals(8));
      // modifiedAt must be bumped so the entry sorts to the top again.
      expect(replaced.modifiedAt.isAfter(original.modifiedAt), isTrue);
    });

    test('StorageFullException message contains sizes', () {
      final e = StorageFullException(100, 50);
      expect(e.toString(), contains('100 bytes'));
      expect(e.toString(), contains('50 bytes'));
    });

    group('ScanStorage.fromEnvironment', () {
      test('applies documented environment variables', () {
        final storage = ScanStorage.fromEnvironment({
          'SCAN_STORAGE_PATH': '/tmp/dartscl-env-test',
          'SCAN_MAX_STORAGE': '512MB',
          'SCAN_STORAGE_FULL_POLICY': 'evict-oldest',
          'SCAN_RETENTION_DAYS': '14',
        });
        expect(storage.baseDir.path, equals('/tmp/dartscl-env-test'));
        expect(storage.maxStorageBytes, equals(512 * 1024 * 1024));
        expect(storage.fullPolicy, equals(StorageFullPolicy.evictOldest));
        expect(storage.retentionDays, equals(14));
      });

      test('falls back to defaults for missing or invalid values', () {
        final storage = ScanStorage.fromEnvironment(<String, String>{
          'SCAN_MAX_STORAGE': 'not-a-size',
          'SCAN_RETENTION_DAYS': 'abc',
        });
        expect(storage.maxStorageBytes, equals(1024 * 1024 * 1024));
        expect(storage.fullPolicy, equals(StorageFullPolicy.error));
        expect(storage.retentionDays, equals(365));
      });
    });

    test('concurrent saves never exceed the storage limit', () async {
      final storage = buildStorage(maxBytes: 1000);

      // Fire 10 parallel 100-byte saves against a 1000-byte limit. Without
      // mutation serialization some of these would race past the limit check.
      final results = await Future.wait(<Future<ScannedFile>>[
        for (var i = 0; i < 10; i++)
          storage.save(
            Uint8List.fromList(List.filled(100, i)),
            mimeType: 'image/jpeg',
          ),
      ]);

      expect(results, hasLength(10));
      final total = storage.list().fold<int>(0, (sum, f) => sum + f.sizeBytes);
      expect(total, lessThanOrEqualTo(1000));
    });

    test('_filePath rejects non-UUID ids defensively', () {
      final storage = buildStorage();
      expect(
        () => storage.pathFor('../../etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
