import 'dart:io';
import 'dart:typed_data';

import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/escl_client.dart';
import 'package:dartscl_backend/src/mock_scanner_service.dart';
import 'package:dartscl_backend/src/pdf_processing_pipeline.dart';
import 'package:dartscl_backend/src/scan_storage.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:uuid/uuid.dart';

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

  try {
    final json = await context.request.json() as Map<String, dynamic>;
    final config = ScanJobConfig.fromJson(json);

    final registry = context.read<ScannerRegistry>();
    final storage = context.read<ScanStorage>();

    // Appending requires a previously stored PDF (id is validated against the
    // storage index, so arbitrary paths can never be constructed).
    if (config.targetMode == TargetMode.append) {
      if (config.targetPdfId == null) {
        return Response.json(
          statusCode: 400,
          body: {'error': 'targetPdfId is required when targetMode is append'},
        );
      }
      final target = storage.get(config.targetPdfId!);
      if (target == null || target.mimeType != 'application/pdf') {
        return Response.json(
          statusCode: 404,
          body: {'error': 'Target PDF not found: ${config.targetPdfId}'},
        );
      }
    }

    final device = registry.getDevice(config.scannerId);

    // Unknown scanner IDs must 404 — only mock-* IDs fall back to dummy data.
    if (device == null && !config.scannerId.startsWith('mock-')) {
      return Response.json(
        statusCode: 404,
        body: {'error': 'Scanner not found: ${config.scannerId}'},
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
    return Response.json(
      statusCode: 507,
      body: {'error': 'storage_full', 'message': e.toString()},
    );
  } on EsclException catch (e) {
    if (e.isBusy) {
      return Response.json(
        statusCode: 503,
        body: {'error': 'scanner_busy'},
      );
    }
    return Response.json(
      statusCode: 500,
      body: {'error': e.message},
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {'error': e.toString()},
    );
  }
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
Future<Response> _appendPdf(
  ScanStorage storage,
  ScanJobConfig config,
  Uint8List imageBytes,
) async {
  final targetId = config.targetPdfId!;
  final tmpDir = Directory.systemTemp;
  final newPagePath = '${tmpDir.path}/${const Uuid().v4()}_newpage.pdf';
  final outputPath = '${tmpDir.path}/${const Uuid().v4()}_output.pdf';

  try {
    final pdfBytes = await PdfProcessingPipeline.convertImageToPdf(imageBytes);
    await File(newPagePath).writeAsBytes(pdfBytes);

    await PdfProcessingPipeline.appendPdfPage(
      existingPdfPath: storage.pathFor(targetId),
      newPagePdfPath: newPagePath,
      outputPath: outputPath,
    );

    final mergedBytes = await File(outputPath).readAsBytes();

    // Same id → replaces the file, keeps its name, bumps modifiedAt so it
    // appears at the top of the history.
    final record = await storage.save(
      mergedBytes,
      mimeType: 'application/pdf',
      id: targetId,
    );
    return _pdfResponse(record, mergedBytes);
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
