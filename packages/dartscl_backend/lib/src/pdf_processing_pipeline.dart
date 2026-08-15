import 'dart:io';
import 'dart:typed_data';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_manipulator/pdf_manipulator.dart';
import 'package:pdf_manipulator/io.dart';

/// Pipeline for processing raw scanned images: software cropping, PDF generation, and native merging.
class PdfProcessingPipeline {
  /// Crops raw image bytes using relative CropRegion (0.0 to 1.0) coordinates.
  static Uint8List cropImage(Uint8List rawBytes, CropRegion crop) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw Exception('Failed to decode raw image bytes for cropping');
    }

    final x = (crop.xRatio.clamp(0.0, 1.0) * decoded.width).round();
    final y = (crop.yRatio.clamp(0.0, 1.0) * decoded.height).round();
    final width = (crop.widthRatio.clamp(0.0, 1.0) * decoded.width).round();
    final height = (crop.heightRatio.clamp(0.0, 1.0) * decoded.height).round();

    final safeX = x.clamp(0, decoded.width - 1);
    final safeY = y.clamp(0, decoded.height - 1);
    final safeWidth = width.clamp(1, decoded.width - safeX);
    final safeHeight = height.clamp(1, decoded.height - safeY);

    final cropped = img.copyCrop(
      decoded,
      x: safeX,
      y: safeY,
      width: safeWidth,
      height: safeHeight,
    );

    return img.encodeJpg(cropped, quality: 90);
  }

  /// Converts image bytes into a single-page PDF document with matching dimensions.
  static Future<Uint8List> convertImageToPdf(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw Exception('Failed to decode image bytes for PDF conversion');
    }

    final pdf = pw.Document();
    final image = pw.MemoryImage(imageBytes);

    final pageFormat = PdfPageFormat(
      decoded.width.toDouble(),
      decoded.height.toDouble(),
      marginAll: 0,
    );

    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (pw.Context context) {
          return pw.FullPage(
            ignoreMargins: true,
            child: pw.Image(image),
          );
        },
      ),
    );

    return pdf.save();
  }

  /// Merges a newly generated PDF to the end of an existing PDF using pdf_manipulator.
  static Future<void> appendPdfPage({
    required String existingPdfPath,
    required String newPagePdfPath,
    required String outputPath,
  }) async {
    final existingFile = File(existingPdfPath);
    final newPageFile = File(newPagePdfPath);

    if (!await existingFile.exists() || !await newPageFile.exists()) {
      throw FileSystemException(
        'One or both input PDF files do not exist.',
        !await existingFile.exists() ? existingPdfPath : newPagePdfPath,
      );
    }

    final pdf = Pdf();
    FileSink? sink;

    try {
      // DataSources direkt erzeugen (nicht erst über pdf.open)
      final existingSource = FileSource(existingFile);
      final newPageSource = FileSource(newPageFile);

      sink = await FileSink.create(File(outputPath));

      // merge erwartet List<DataSource>
      await pdf.merge([existingSource, newPageSource], sink);
    } finally {
      await sink?.close();
    }
  }

  /// Deletes a temporary file safely without throwing exceptions if missing.
  static Future<void> deleteTempFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
