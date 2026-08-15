import 'dart:io';
import 'dart:typed_data';

import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/escl_client.dart';
import 'package:dartscl_backend/src/mock_scanner_service.dart';
import 'package:dartscl_backend/src/pdf_processing_pipeline.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:uuid/uuid.dart';

/// Matches the UUID format produced by `Uuid().v4()` (8-4-4-4-12 hex).
///
/// Used to validate `targetPdfId` before it is interpolated into a file
/// path, preventing path traversal through user-supplied input.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Handles POST /api/v1/scan — accepts a [ScanJobConfig] JSON body.
///
/// For preview scans: returns raw JPEG bytes.
/// For final scans with JPEG format: returns JPEG bytes.
/// For final scans with PDF format: converts to PDF, appends if needed,
/// and returns the PDF bytes.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  try {
    final json = await context.request.json() as Map<String, dynamic>;
    final config = ScanJobConfig.fromJson(json);

    // targetPdfId is interpolated into a file path below — only accept
    // backend-generated UUIDs to prevent path traversal.
    if (config.targetPdfId != null &&
        !_uuidPattern.hasMatch(config.targetPdfId!)) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Invalid targetPdfId format'},
      );
    }

    // Appending requires a previously stored PDF from this backend.
    if (config.targetMode == TargetMode.append && config.targetPdfId == null) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'targetPdfId is required when targetMode is append'},
      );
    }

    final registry = context.read<ScannerRegistry>();
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
      // Preview is always JPEG for browser display
      return Response.bytes(
        body: imageBytes,
        headers: {
          'Content-Type': 'image/jpeg',
          'Content-Disposition': 'inline; filename="preview.jpg"',
        },
      );
    }

    // --- Final scan handling ---
    final isPdf = config.documentFormat == 'application/pdf';

    if (!isPdf) {
      // Return raw JPEG/PNG bytes
      return Response.bytes(
        body: imageBytes,
        headers: {
          'Content-Type': 'image/jpeg',
          'Content-Disposition':
              'attachment; filename="scan-${DateTime.now().millisecondsSinceEpoch}.jpg"',
        },
      );
    }

    // --- PDF output path ---
    final tmpDir = Directory.systemTemp;
    final scanId = const Uuid().v4();
    final newPagePath = '${tmpDir.path}/${scanId}_newpage.pdf';
    final outputPath = '${tmpDir.path}/${scanId}_output.pdf';

    try {
      // Convert scanned image to a single-page PDF
      final pdfBytes =
          await PdfProcessingPipeline.convertImageToPdf(imageBytes);
      await File(newPagePath).writeAsBytes(pdfBytes);

      Uint8List resultBytes;

      if (config.targetMode == TargetMode.append) {
        // Append to existing PDF (targetPdfId validated above)
        final existingPath = '${tmpDir.path}/${config.targetPdfId}.pdf';
        if (!await File(existingPath).exists()) {
          throw Exception('Target PDF not found: ${config.targetPdfId}');
        }

        await PdfProcessingPipeline.appendPdfPage(
          existingPdfPath: existingPath,
          newPagePdfPath: newPagePath,
          outputPath: outputPath,
        );

        resultBytes = await File(outputPath).readAsBytes();

        // Clean up temp files
        await PdfProcessingPipeline.deleteTempFile(newPagePath);
        await PdfProcessingPipeline.deleteTempFile(outputPath);
      } else {
        // New PDF — just return the single page
        resultBytes = pdfBytes;
        await PdfProcessingPipeline.deleteTempFile(newPagePath);
      }

      // Persist the result so future append scans can chain onto it:
      // a new PDF is stored under its fresh scanId (returned as X-Scan-Id),
      // an appended PDF overwrites the previously stored file.
      final storedPath = config.targetMode == TargetMode.newPdf
          ? '${tmpDir.path}/$scanId.pdf'
          : '${tmpDir.path}/${config.targetPdfId}.pdf';
      await File(storedPath).writeAsBytes(resultBytes);

      // The client needs a stable scan ID to chain append scans: for a new
      // PDF that is the fresh scanId, for an append it is the targetPdfId
      // under which the merged result was persisted.
      final returnedScanId =
          config.targetMode == TargetMode.append ? config.targetPdfId! : scanId;

      return Response.bytes(
        body: resultBytes,
        headers: {
          'Content-Type': 'application/pdf',
          'Content-Disposition':
              'attachment; filename="scan-${DateTime.now().millisecondsSinceEpoch}.pdf"',
          'X-Scan-Id': returnedScanId,
        },
      );
    } finally {
      // Ensure temp files are cleaned up even on errors
      await PdfProcessingPipeline.deleteTempFile(newPagePath);
      await PdfProcessingPipeline.deleteTempFile(outputPath);
    }
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
