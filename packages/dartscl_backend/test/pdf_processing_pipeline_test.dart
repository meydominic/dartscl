import 'dart:io';
import 'dart:typed_data';

import 'package:dartscl_backend/src/pdf_processing_pipeline.dart';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';
import 'package:test/test.dart';

/// Creates a solid-black JPEG of the given size, standing in for a scanner page.
Uint8List _jpegOfSize(int width, int height) {
  final image = img.Image(width: width, height: height);
  return img.encodeJpg(image);
}

/// Returns the page count of the PDF stored at [path].
///
/// Uses the same engine that performs the merge, so the assertion is
/// independent of how `package:pdf` lays out its page dictionaries.
Future<int> _pageCount(String path) async {
  final pdf = Pdf();
  try {
    final info = await pdf.info(PdfFile(File(path)));
    return info.pageCount;
  } finally {
    await pdf.dispose();
  }
}

/// Returns [count] bytes that do not form a valid PDF.
Uint8List _garbage(int count) => Uint8List.fromList(List.filled(count, 0x41));

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dartscl_pdf_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PdfProcessingPipeline.cropImage', () {
    test('crops to the requested relative region', () {
      final source = _jpegOfSize(200, 200);

      final cropped = PdfProcessingPipeline.cropImage(
        source,
        const CropRegion(xRatio: 0.5, yRatio: 0.5, widthRatio: 0.5, heightRatio: 0.5),
      );

      final decoded = img.decodeImage(cropped)!;
      expect(decoded.width, equals(100));
      expect(decoded.height, equals(100));
    });

    test('clamps out-of-range and zero-size regions instead of throwing', () {
      final source = _jpegOfSize(120, 80);

      final cropped = PdfProcessingPipeline.cropImage(
        source,
        const CropRegion(xRatio: 1.5, yRatio: -0.2, widthRatio: 0, heightRatio: 5),
      );

      final decoded = img.decodeImage(cropped)!;
      expect(decoded.width, greaterThanOrEqualTo(1));
      expect(decoded.height, greaterThanOrEqualTo(1));
      expect(decoded.width, lessThanOrEqualTo(120));
      expect(decoded.height, lessThanOrEqualTo(80));
    });

    test('throws a descriptive exception for undecodable input', () {
      expect(
        () => PdfProcessingPipeline.cropImage(
          _garbage(32),
          const CropRegion(
            xRatio: 0,
            yRatio: 0,
            widthRatio: 1,
            heightRatio: 1,
          ),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('PdfProcessingPipeline.convertImageToPdf', () {
    test('produces a single-page PDF', () async {
      final pdfBytes =
          await PdfProcessingPipeline.convertImageToPdf(_jpegOfSize(80, 120));
      final path = '${tempDir.path}/single.pdf';
      await File(path).writeAsBytes(pdfBytes);

      expect(String.fromCharCodes(pdfBytes.take(5)), equals('%PDF-'));
      expect(await _pageCount(path), equals(1));
    });

    test('throws a descriptive exception for undecodable input', () async {
      await expectLater(
        PdfProcessingPipeline.convertImageToPdf(_garbage(32)),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('PdfProcessingPipeline.appendPdfPage', () {
    test('appends the second document and leaves the inputs untouched', () async {
      final existingPath = '${tempDir.path}/existing.pdf';
      final newPagePath = '${tempDir.path}/newpage.pdf';
      final outputPath = '${tempDir.path}/merged.pdf';

      final existingBytes = await PdfProcessingPipeline.convertImageToPdf(
        _jpegOfSize(60, 90),
      );
      final newPageBytes = await PdfProcessingPipeline.convertImageToPdf(
        _jpegOfSize(60, 90),
      );
      await File(existingPath).writeAsBytes(existingBytes);
      await File(newPagePath).writeAsBytes(newPageBytes);

      await PdfProcessingPipeline.appendPdfPage(
        existingPdfPath: existingPath,
        newPagePdfPath: newPagePath,
        outputPath: outputPath,
      );

      expect(await _pageCount(outputPath), equals(2));
      // Appending must not mutate its inputs — the caller still needs them
      // (e.g. for a retry or for the storage record).
      expect(await File(existingPath).readAsBytes(), equals(existingBytes));
      expect(await File(newPagePath).readAsBytes(), equals(newPageBytes));
    });

    test('reports which input file is missing', () async {
      final existingPath = '${tempDir.path}/existing.pdf';
      await File(existingPath).writeAsBytes(
        await PdfProcessingPipeline.convertImageToPdf(_jpegOfSize(40, 40)),
      );

      await expectLater(
        PdfProcessingPipeline.appendPdfPage(
          existingPdfPath: existingPath,
          newPagePdfPath: '${tempDir.path}/missing.pdf',
          outputPath: '${tempDir.path}/merged.pdf',
        ),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.path,
            'path',
            contains('missing.pdf'),
          ),
        ),
      );
    });

    test('fails on a corrupt base document instead of writing a broken file',
        () async {
      final existingPath = '${tempDir.path}/corrupt.pdf';
      final newPagePath = '${tempDir.path}/newpage.pdf';
      final outputPath = '${tempDir.path}/merged.pdf';

      await File(existingPath).writeAsBytes(_garbage(64));
      await File(newPagePath).writeAsBytes(
        await PdfProcessingPipeline.convertImageToPdf(_jpegOfSize(40, 40)),
      );

      await expectLater(
        PdfProcessingPipeline.appendPdfPage(
          existingPdfPath: existingPath,
          newPagePdfPath: newPagePath,
          outputPath: outputPath,
        ),
        throwsA(anything),
      );
    });
  });

  group('PdfProcessingPipeline.deleteTempFile', () {
    test('removes an existing file and ignores a missing one', () async {
      final path = '${tempDir.path}/temp.pdf';
      await File(path).writeAsBytes([1, 2, 3]);

      await PdfProcessingPipeline.deleteTempFile(path);
      expect(File(path).existsSync(), isFalse);

      // Deleting again must not throw — cleanup runs from `finally` blocks.
      await PdfProcessingPipeline.deleteTempFile(path);
    });
  });
}
