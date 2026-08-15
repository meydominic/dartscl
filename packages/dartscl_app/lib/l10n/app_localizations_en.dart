// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'DartSCL Web Scanner';

  @override
  String get reloadScanners => 'Reload scanners';

  @override
  String get scanHistory => 'Scan history';

  @override
  String get backToScan => 'Back to scan';

  @override
  String get scannerSelection => 'SCANNER SELECTION';

  @override
  String get settings => 'SETTINGS';

  @override
  String get noScannersFound => 'No scanners found.';

  @override
  String errorText(String err) {
    return 'Error: $err';
  }

  @override
  String get resolutionDpi => 'Resolution (DPI)';

  @override
  String get colorMode => 'Color mode';

  @override
  String get outputFormat => 'Output format';

  @override
  String get source => 'Source';

  @override
  String get appendTo => 'Append to';

  @override
  String get jpegImage => 'JPEG image';

  @override
  String get pdfDocument => 'PDF document';

  @override
  String get flatbedPlaten => 'Flatbed (Platen)';

  @override
  String get documentFeederAdf => 'Document Feeder (ADF)';

  @override
  String get newPdf => 'New PDF';

  @override
  String get crop => 'CROP';

  @override
  String get previewScan => 'Preview scan';

  @override
  String get scan => 'Scan';

  @override
  String get scanCropRegion => 'Scan crop region';

  @override
  String statusLabel(String status) {
    return 'Status: $status';
  }

  @override
  String get dragCropHint =>
      'Drag a rectangle on the image to select a crop region';

  @override
  String get clickPreviewHint => 'Click \"Preview scan\" to load the image';

  @override
  String get noScansYet => 'No scans yet.';

  @override
  String get openInBrowser => 'Open in browser';

  @override
  String get download => 'Download';

  @override
  String get delete => 'Delete';

  @override
  String get refreshHistory => 'Refresh history';

  @override
  String get ready => 'Ready';

  @override
  String get loadingPreview => 'Loading preview...';

  @override
  String get previewReady =>
      'Preview ready — select a crop region or scan directly.';

  @override
  String previewError(String error) {
    return 'Preview error: $error';
  }

  @override
  String get scanningDocument => 'Scanning document...';

  @override
  String get scanningCropRegion => 'Scanning crop region...';

  @override
  String scanError(String error) {
    return 'Scan error: $error';
  }

  @override
  String saved(String name) {
    return 'Saved: $name';
  }

  @override
  String savedStatus(String name, String size) {
    return 'Saved: $name ($size bytes)';
  }

  @override
  String deletedStatus(String name) {
    return 'Deleted \"$name\".';
  }

  @override
  String deleteError(String error) {
    return 'Delete error: $error';
  }
}
