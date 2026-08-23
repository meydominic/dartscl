import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'DartSCL Web Scanner'**
  String get appTitle;

  /// No description provided for @reloadScanners.
  ///
  /// In en, this message translates to:
  /// **'Reload scanners'**
  String get reloadScanners;

  /// No description provided for @scanHistory.
  ///
  /// In en, this message translates to:
  /// **'Scan history'**
  String get scanHistory;

  /// No description provided for @backToScan.
  ///
  /// In en, this message translates to:
  /// **'Back to scan'**
  String get backToScan;

  /// No description provided for @scannerSelection.
  ///
  /// In en, this message translates to:
  /// **'SCANNER SELECTION'**
  String get scannerSelection;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'SETTINGS'**
  String get settings;

  /// No description provided for @noScannersFound.
  ///
  /// In en, this message translates to:
  /// **'No scanners found.'**
  String get noScannersFound;

  /// Generic error message with details
  ///
  /// In en, this message translates to:
  /// **'Error: {err}'**
  String errorText(String err);

  /// No description provided for @resolutionDpi.
  ///
  /// In en, this message translates to:
  /// **'Resolution (DPI)'**
  String get resolutionDpi;

  /// No description provided for @colorMode.
  ///
  /// In en, this message translates to:
  /// **'Color mode'**
  String get colorMode;

  /// No description provided for @outputFormat.
  ///
  /// In en, this message translates to:
  /// **'Output format'**
  String get outputFormat;

  /// No description provided for @source.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get source;

  /// No description provided for @appendTo.
  ///
  /// In en, this message translates to:
  /// **'Append to'**
  String get appendTo;

  /// No description provided for @jpegImage.
  ///
  /// In en, this message translates to:
  /// **'JPEG image'**
  String get jpegImage;

  /// No description provided for @pdfDocument.
  ///
  /// In en, this message translates to:
  /// **'PDF document'**
  String get pdfDocument;

  /// No description provided for @flatbedPlaten.
  ///
  /// In en, this message translates to:
  /// **'Flatbed (Platen)'**
  String get flatbedPlaten;

  /// No description provided for @documentFeederAdf.
  ///
  /// In en, this message translates to:
  /// **'Document Feeder (ADF)'**
  String get documentFeederAdf;

  /// No description provided for @newPdf.
  ///
  /// In en, this message translates to:
  /// **'New PDF'**
  String get newPdf;

  /// No description provided for @crop.
  ///
  /// In en, this message translates to:
  /// **'CROP'**
  String get crop;

  /// No description provided for @previewScan.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get previewScan;

  /// No description provided for @scan.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get scan;

  /// No description provided for @scanCropRegion.
  ///
  /// In en, this message translates to:
  /// **'Scan crop region'**
  String get scanCropRegion;

  /// Status bar prefix followed by the current status
  ///
  /// In en, this message translates to:
  /// **'Status: {status}'**
  String statusLabel(String status);

  /// No description provided for @dragCropHint.
  ///
  /// In en, this message translates to:
  /// **'Drag a rectangle on the image to select a crop region'**
  String get dragCropHint;

  /// No description provided for @clickPreviewHint.
  ///
  /// In en, this message translates to:
  /// **'Click \"Preview\" to load the image'**
  String get clickPreviewHint;

  /// No description provided for @noScansYet.
  ///
  /// In en, this message translates to:
  /// **'No scans yet.'**
  String get noScansYet;

  /// No description provided for @openInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get openInBrowser;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @refreshHistory.
  ///
  /// In en, this message translates to:
  /// **'Refresh history'**
  String get refreshHistory;

  /// No description provided for @ready.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get ready;

  /// No description provided for @loadingPreview.
  ///
  /// In en, this message translates to:
  /// **'Loading preview...'**
  String get loadingPreview;

  /// No description provided for @previewReady.
  ///
  /// In en, this message translates to:
  /// **'Preview ready — select a crop region or scan directly.'**
  String get previewReady;

  /// Preview scan failure message
  ///
  /// In en, this message translates to:
  /// **'Preview error: {error}'**
  String previewError(String error);

  /// No description provided for @scanningDocument.
  ///
  /// In en, this message translates to:
  /// **'Scanning document...'**
  String get scanningDocument;

  /// No description provided for @scanningCropRegion.
  ///
  /// In en, this message translates to:
  /// **'Scanning crop region...'**
  String get scanningCropRegion;

  /// Final scan failure message
  ///
  /// In en, this message translates to:
  /// **'Scan error: {error}'**
  String scanError(String error);

  /// Toast shown after a scan is stored
  ///
  /// In en, this message translates to:
  /// **'Saved: {name}'**
  String saved(String name);

  /// Status text after a scan is stored
  ///
  /// In en, this message translates to:
  /// **'Saved: {name} ({size} bytes)'**
  String savedStatus(String name, String size);

  /// Status text after a stored file is deleted
  ///
  /// In en, this message translates to:
  /// **'Deleted \"{name}\".'**
  String deletedStatus(String name);

  /// File deletion failure message
  ///
  /// In en, this message translates to:
  /// **'Delete error: {error}'**
  String deleteError(String error);

  /// No description provided for @settingsSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsSheetTitle;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Show settings'**
  String get openSettings;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
