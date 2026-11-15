import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/escl_client.dart';
import 'package:dartscl_backend/src/mock_scanner_service.dart';
import 'package:dartscl_backend/src/pdf_processing_pipeline.dart';
import 'package:dartscl_backend/src/scan_storage.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

/// Logger for the scan route — every failed scan is logged so the server
/// console shows why a page was not persisted.
final Logger _log = Logger('ScanRoute');

/// Maximum accepted request-body size.
///
/// A scan configuration is a few hundred bytes; anything larger is not a
/// legitimate request and must not be buffered into memory.
const int _maxRequestBytes = 16 * 1024;

/// Handles POST /api/v1/scan — accepts a [ScanJobConfig] JSON body.
///
/// Preview scans return raw JPEG bytes (never persisted). Final scans are
/// persisted to [ScanStorage] (JPEG or PDF) and returned for download, with
/// the stored file's id in the `X-Scan-Id` header so the client can select
/// it as the next append target.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  final contentLength = int.tryParse(
    context.request.headers['content-length'] ?? '',
  );
  if (contentLength != null && contentLength > _maxRequestBytes) {
    return Response.json(
      statusCode: 413,
      body: {'error': 'request_too_large'},
    );
  }

  final bodyBytes = await _readBodyLimited(context.request);
  if (bodyBytes == null) {
    return Response.json(
      statusCode: 413,
      body: {'error': 'request_too_large'},
    );
  }

  final ScanJobConfig config;
  try {
    final json = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    config = ScanJobConfig.fromJson(json);
  } on FormatException {
    // Malformed JSON is a client error, not a server failure.
    return Response.json(
      statusCode: 400,
      body: {'error': 'invalid_scan_config'},
    );
  } on TypeError {
    return Response.json(
      statusCode: 400,
      body: {'error': 'invalid_scan_config'},
    );
  } on ArgumentError {
    // enumDecode throws this for unknown enum values.
    return Response.json(
      statusCode: 400,
      body: {'error': 'invalid_scan_config'},
    );
  }

  try {
    final registry = context.read<ScannerRegistry>();
    final storage = context.read<ScanStorage>();

    // Appending requires a previously stored PDF (id is validated against the
    // storage index, so arbitrary paths can never be constructed).
    if (config.targetMode == TargetMode.append) {
      if (config.targetPdfId == null) {
        return Response.json(
          statusCode: 400,
          body: {'error': 'target_pdf_required'},
        );
      }
      final target = storage.get(config.targetPdfId!);
      if (target == null || target.mimeType != 'application/pdf') {
        return Response.json(
          statusCode: 404,
          body: {'error': 'target_pdf_missing'},
        );
      }
    }

    final device = registry.getDevice(config.scannerId);

    // Unknown scanner IDs must 404 — only mock-* IDs fall back to dummy data.
    if (device == null && !config.scannerId.startsWith('mock-')) {
      return Response.json(
        statusCode: 404,
        body: {'error': 'scanner_missing'},
      );
    }

    // Reject settings the scanner cannot honour. Besides giving the user a
    // usable error, this keeps unvalidated caller input out of the eSCL XML.
    final invalidReason = _validateAgainstCapabilities(
      registry.getCachedCapabilities(config.scannerId),
      config,
    );
    if (invalidReason != null) {
      _log.warning('Rejected scan config for ${config.scannerId}: $invalidReason');
      return Response.json(
        statusCode: 400,
        body: {'error': 'invalid_scan_config', 'detail': invalidReason},
      );
    }

    var imageBytes = config.scannerId.startsWith('mock-')
        ? mockScannerService.dummyImage
        : await registry.esclClient.executeScanJob(device!, config);

    // Apply software crop if specified
    if (config.crop != null) {
      imageBytes = PdfProcessingPipeline.cropImage(imageBytes, config.crop!);
    }

    if (config.intent == ScanIntent.preview) {
      // Preview is always JPEG for browser display — never persisted.
      return Response.bytes(
        body: imageBytes,
        headers: {
          'Content-Type': 'image/jpeg',
          'Content-Disposition': 'inline; filename="preview.jpg"',
        },
      );
    }

    // --- Final scan: persist the result, then return it for download ---
    if (config.documentFormat != 'application/pdf') {
      final record = await storage.save(imageBytes, mimeType: 'image/jpeg');
      return Response.bytes(
        body: imageBytes,
        headers: {
          'Content-Type': 'image/jpeg',
          'Content-Disposition': 'attachment; filename="${record.name}"',
          'X-Scan-Id': record.id,
          'X-Scan-Name': record.name,
        },
      );
    }

    if (config.targetMode == TargetMode.append) {
      return await _appendPdf(storage, config, imageBytes);
    }
    return await _newPdf(storage, imageBytes);
  } on StorageFullException catch (e) {
    _log.warning('Scan rejected: storage full.', e);
    return Response.json(
      statusCode: 507,
      body: {'error': 'storage_full'},
    );
  } on EsclException catch (e, stackTrace) {
    if (e.isBusy) {
      _log.warning('Scan rejected: scanner busy.', e);
      return Response.json(
        statusCode: 503,
        body: {'error': 'scanner_busy'},
      );
    }
    if (e.statusCode == 504) {
      _log.severe('Scan timed out (job cancelled on the scanner).', e,
          stackTrace);
      return Response.json(
        statusCode: 504,
        body: {'error': 'scan_timeout'},
      );
    }
    // Details stay in the log: exception text can contain scanner URLs and
    // response bodies, which LAN clients must not receive.
    _log.severe('Scan failed (eSCL error).', e, stackTrace);
    return Response.json(
      statusCode: 502,
      body: {'error': 'scanner_error'},
    );
  } catch (e, stackTrace) {
    _log.severe('Scan failed.', e, stackTrace);
    return Response.json(
      statusCode: 500,
      body: {'error': 'scan_failed'},
    );
  }
}

/// Reads the request body into memory, refusing bodies above
/// [_maxRequestBytes].
///
/// A `Content-Length` check alone is not enough: a chunked request carries no
/// length header, and `request.json()` would buffer the whole stream.
///
/// Returns `null` when the limit is exceeded.
Future<Uint8List?> _readBodyLimited(Request request) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request.bytes()) {
    builder.add(chunk);
    if (builder.length > _maxRequestBytes) return null;
  }
  return builder.takeBytes();
}

/// Checks [config] against the capabilities cached for its scanner.
///
/// Returns a human-readable reason when the request cannot be honoured, or
/// `null` when it is acceptable. A missing capabilities map does not block the
/// request: mock devices and scanners whose capabilities could not be fetched
/// have no allowlist to check against, and the scanner itself rejects invalid
/// settings.
///
/// This also keeps caller-controlled strings out of the eSCL XML payload, since
/// every accepted value is a member of a fixed allowlist.
String? _validateAgainstCapabilities(
  Map<String, dynamic>? caps,
  ScanJobConfig config,
) {
  if (caps == null || caps.isEmpty) return null;

  final dpis = (caps['dpi'] as List<dynamic>?)?.cast<int>();
  if (dpis != null && dpis.isNotEmpty && !dpis.contains(config.dpi)) {
    return 'dpi ${config.dpi} is not supported (allowed: $dpis)';
  }

  final colorModes = (caps['colorModes'] as List<dynamic>?)?.cast<String>();
  if (colorModes != null &&
      colorModes.isNotEmpty &&
      !colorModes.contains(config.colorMode)) {
    return 'colorMode "${config.colorMode}" is not supported '
        '(allowed: $colorModes)';
  }

  // NOTE: `documentFormat` is intentionally NOT validated here. It describes
  // what the *backend* returns (JPEG bytes or a locally built PDF), while the
  // scanner always delivers JPEG (`DocumentFormatExt: image/jpeg`). A scanner
  // that advertises only `image/jpeg` can therefore still produce PDFs.

  final sources = (caps['sources'] as List<dynamic>?)?.cast<String>();
  if (sources != null && sources.isNotEmpty) {
    final requested = config.source.name; // 'platen' | 'adf'
    if (!sources.contains(requested)) {
      return 'source "$requested" is not supported (allowed: $sources)';
    }
  }

  return null;
}

/// Converts the scanned image to a single-page PDF and stores it as a new
/// file in [storage].
Future<Response> _newPdf(
  ScanStorage storage,
  Uint8List imageBytes,
) async {
  final pdfBytes = await PdfProcessingPipeline.convertImageToPdf(imageBytes);
  final record = await storage.save(pdfBytes, mimeType: 'application/pdf');
  return _pdfResponse(record, pdfBytes);
}

/// Appends the scanned page to an existing PDF (identified by
/// [ScanJobConfig.targetPdfId]), replacing it in [storage] under the same id.
///
/// Only the read-merge-write runs under the storage lock: concurrent appends
/// would otherwise read the same base version and silently drop one of the
/// pages while both callers receive HTTP 200. The (CPU/FFI-heavy) page
/// conversion happens before the lock is taken, so a slow page does not block
/// saves and deletes of other scans.
Future<Response> _appendPdf(
  ScanStorage storage,
  ScanJobConfig config,
  Uint8List imageBytes,
) async {
  final targetId = config.targetPdfId!;

  // Intermediates live next to the stored scans: the runtime image has no
  // /tmp, and the same filesystem keeps the merge cheap.
  final tmpDir = await storage.ensureTempDir();
  final newPagePath = '${tmpDir.path}/${const Uuid().v4()}_newpage.pdf';
  final outputPath = '${tmpDir.path}/${const Uuid().v4()}_output.pdf';

  try {
    final pdfBytes = await PdfProcessingPipeline.convertImageToPdf(imageBytes);
    await File(newPagePath).writeAsBytes(pdfBytes);

    return await storage.runExclusive(() async {
      await PdfProcessingPipeline.appendPdfPage(
        existingPdfPath: storage.pathFor(targetId),
        newPagePdfPath: newPagePath,
        outputPath: outputPath,
      );

      final mergedBytes = await File(outputPath).readAsBytes();

      // Same id → replaces the file, keeps its name, bumps modifiedAt so it
      // appears at the top of the history. The lock is already held here, so
      // the unlocked save variant is the correct call (save() would deadlock).
      final record = await storage.saveWithinLock(
        mergedBytes,
        mimeType: 'application/pdf',
        id: targetId,
      );
      return _pdfResponse(record, mergedBytes);
    });
  } finally {
    await PdfProcessingPipeline.deleteTempFile(newPagePath);
    await PdfProcessingPipeline.deleteTempFile(outputPath);
  }
}

/// Builds a PDF download response with the stored file's id in `X-Scan-Id`
/// and its display name in `X-Scan-Name`.
Response _pdfResponse(ScannedFile record, Uint8List bytes) {
  return Response.bytes(
    body: bytes,
    headers: {
      'Content-Type': 'application/pdf',
      'Content-Disposition': 'attachment; filename="${record.name}"',
      'X-Scan-Id': record.id,
      'X-Scan-Name': record.name,
    },
  );
}
