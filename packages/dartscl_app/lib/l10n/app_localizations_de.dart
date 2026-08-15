// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'DartSCL Web Scanner';

  @override
  String get reloadScanners => 'Scanner neu laden';

  @override
  String get scanHistory => 'Scan-Verlauf';

  @override
  String get backToScan => 'Zurück zum Scan';

  @override
  String get scannerSelection => 'SCANNER-AUSWAHL';

  @override
  String get settings => 'EINSTELLUNGEN';

  @override
  String get noScannersFound => 'Keine Scanner gefunden.';

  @override
  String errorText(String err) {
    return 'Fehler: $err';
  }

  @override
  String get resolutionDpi => 'Auflösung (DPI)';

  @override
  String get colorMode => 'Farbmodus';

  @override
  String get outputFormat => 'Ausgabeformat';

  @override
  String get source => 'Quelle';

  @override
  String get appendTo => 'Anhängen an';

  @override
  String get jpegImage => 'JPEG-Bild';

  @override
  String get pdfDocument => 'PDF-Dokument';

  @override
  String get flatbedPlaten => 'Flachbett (Platen)';

  @override
  String get documentFeederAdf => 'Dokumenteneinzug (ADF)';

  @override
  String get newPdf => 'Neue PDF';

  @override
  String get crop => 'AUSSCHNITT';

  @override
  String get previewScan => 'Vorschau scannen';

  @override
  String get scan => 'Scannen';

  @override
  String get scanCropRegion => 'Ausschnitt scannen';

  @override
  String statusLabel(String status) {
    return 'Status: $status';
  }

  @override
  String get dragCropHint =>
      'Ziehen Sie ein Rechteck auf dem Bild, um einen Ausschnitt auszuwählen';

  @override
  String get clickPreviewHint =>
      'Klicken Sie auf „Vorschau scannen“, um das Bild zu laden';

  @override
  String get noScansYet => 'Noch keine Scans.';

  @override
  String get openInBrowser => 'Im Browser öffnen';

  @override
  String get download => 'Herunterladen';

  @override
  String get delete => 'Löschen';

  @override
  String get refreshHistory => 'Verlauf aktualisieren';

  @override
  String get ready => 'Bereit';

  @override
  String get loadingPreview => 'Vorschau wird geladen …';

  @override
  String get previewReady =>
      'Vorschau bereit — Ausschnitt auswählen oder direkt scannen.';

  @override
  String previewError(String error) {
    return 'Vorschau-Fehler: $error';
  }

  @override
  String get scanningDocument => 'Dokument wird gescannt …';

  @override
  String get scanningCropRegion => 'Ausschnitt wird gescannt …';

  @override
  String scanError(String error) {
    return 'Scan-Fehler: $error';
  }

  @override
  String saved(String name) {
    return 'Gespeichert: $name';
  }

  @override
  String savedStatus(String name, String size) {
    return 'Gespeichert: $name ($size Bytes)';
  }

  @override
  String deletedStatus(String name) {
    return '„$name“ gelöscht.';
  }

  @override
  String deleteError(String error) {
    return 'Lösch-Fehler: $error';
  }
}
