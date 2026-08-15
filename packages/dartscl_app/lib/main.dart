import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'api_service.dart';
import 'crop_overlay.dart';
import 'l10n/app_localizations.dart';

void main() {
  runApp(
    const ProviderScope(
      child: DartSclWebApp(),
    ),
  );
}

/// Root widget of the DartSCL Web Scanner application.
///
/// Builds a Material 3 theme (light and dark, following the system) with
/// Inter/Outfit typography, and English/German localizations (following the
/// system language). All colors come from the [ColorScheme] roles; the UI
/// never hardcodes palette values.
class DartSclWebApp extends StatelessWidget {
  const DartSclWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DartSCL AirScan Web',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const MainScanScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0284C7),
      brightness: brightness,
    );
    final base = ThemeData(brightness: brightness, colorScheme: scheme);

    // Inter for body text, Outfit for large headings.
    final inter = GoogleFonts.interTextTheme(base.textTheme);
    final outfit = GoogleFonts.outfitTextTheme(base.textTheme);
    final textTheme = inter.copyWith(titleLarge: outfit.titleLarge);

    final borderRadius = BorderRadius.circular(12);

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerLow,
        elevation: 0,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.bold,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    );
  }
}

/// Main scan screen with a left sidebar for controls and a right preview area.
///
/// The sidebar provides scanner selection, scan configuration (DPI, color mode,
/// source, target mode), crop info display, and action buttons. The right area
/// shows a preview image with an interactive crop overlay. A history view can
/// be toggled from the app bar.
class MainScanScreen extends ConsumerStatefulWidget {
  const MainScanScreen({super.key});

  @override
  ConsumerState<MainScanScreen> createState() => _MainScanScreenState();
}

class _MainScanScreenState extends ConsumerState<MainScanScreen>
    with SingleTickerProviderStateMixin {
  int _dpi = 300;
  String _colorMode = 'RGB24';
  String _documentFormat = 'image/jpeg';
  DocumentSource _source = DocumentSource.platen;
  bool _isScanning = false;

  /// Whether the history view (instead of the scan view) is shown.
  bool _showHistory = false;

  /// ID of the PDF that new pages should be appended to. `null` means
  /// "create a new PDF". Auto-set to the most recently created/appended PDF
  /// so it is pre-selected in the append-target dropdown.
  String? _targetPdfId;

  /// Drives the rotating status icon while a scan is in progress.
  late final AnimationController _spinnerController;

  AppLocalizations get _l10n => AppLocalizations.of(context)!;

  ColorScheme get _scheme => Theme.of(context).colorScheme;

  TextTheme get _textTheme => Theme.of(context).textTheme;

  @override
  void initState() {
    super.initState();
    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void dispose() {
    _spinnerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final scheme = _scheme;
    final scannersAsync = ref.watch(scannersProvider);
    final selectedScannerId = ref.watch(selectedScannerIdProvider);
    final capsAsync = ref.watch(capabilitiesProvider);
    final previewBytes = ref.watch(previewImageProvider);
    final statusText = ref.watch(scanStatusProvider);
    final cropRegion = ref.watch(cropRegionProvider);

    final displayStatus = statusText.isEmpty ? l10n.ready : statusText;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.scanner, color: scheme.primary),
            const SizedBox(width: 12),
            Text(l10n.appTitle),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _showHistory ? Icons.scanner : Icons.history,
              color: scheme.primary,
            ),
            onPressed: () => setState(() => _showHistory = !_showHistory),
            tooltip: _showHistory ? l10n.backToScan : l10n.scanHistory,
          ),
          if (!_showHistory)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.refresh(scannersProvider),
              tooltip: l10n.reloadScanners,
            ),
        ],
      ),
      body: _showHistory
          ? _buildHistoryView()
          : Row(
              children: [
                // Left Sidebar: Controls & Configuration
                _buildSidebar(
                  scannersAsync: scannersAsync,
                  selectedScannerId: selectedScannerId,
                  capsAsync: capsAsync,
                  cropRegion: cropRegion,
                ),
                // Right Area: Interactive Preview & Crop Canvas
                _buildPreviewArea(
                  previewBytes: previewBytes,
                  statusText: displayStatus,
                  isScanning: _isScanning,
                  cropRegion: cropRegion,
                ),
              ],
            ),
    );
  }

  /// Builds the left sidebar with scanner selection, settings, and action buttons.
  Widget _buildSidebar({
    required AsyncValue<List<ScannerDevice>> scannersAsync,
    required String? selectedScannerId,
    required AsyncValue<Map<String, dynamic>> capsAsync,
    required CropRegion? cropRegion,
  }) {
    final l10n = _l10n;
    return Container(
      width: 340,
      color: _scheme.surfaceContainerLow,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(l10n.scannerSelection),
          const SizedBox(height: 10),
          _buildScannerSelector(scannersAsync, selectedScannerId),
          const SizedBox(height: 24),
          _sectionLabel(l10n.settings),
          const SizedBox(height: 12),
          _buildCapabilitiesSettings(capsAsync),
          const SizedBox(height: 12),
          _buildDocumentFormatDropdown(capsAsync),
          const SizedBox(height: 12),
          _buildSourceDropdown(),
          // Only show append-target when PDF output is selected
          if (_documentFormat == 'application/pdf') ...[
            const SizedBox(height: 12),
            _buildPdfTargetDropdown(),
          ],
          if (cropRegion != null) ...[
            const SizedBox(height: 16),
            _buildCropInfo(cropRegion),
          ],
          const Spacer(),
          _buildActionButtons(selectedScannerId, cropRegion),
        ],
      ),
    );
  }

  /// Renders a styled section header label.
  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: _textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: _scheme.onSurfaceVariant,
        letterSpacing: 1.2,
      ),
    );
  }

  /// Builds the scanner selection dropdown.
  Widget _buildScannerSelector(
    AsyncValue<List<ScannerDevice>> scannersAsync,
    String? selectedScannerId,
  ) {
    final l10n = _l10n;
    return scannersAsync.when(
      data: (scanners) {
        if (scanners.isEmpty) {
          return Text(l10n.noScannersFound);
        }
        if (selectedScannerId == null && scanners.isNotEmpty) {
          Future.microtask(() {
            ref
                .read(selectedScannerIdProvider.notifier)
                .setScannerId(scanners.first.id);
          });
        }
        final selectedId = selectedScannerId ?? scanners.first.id;
        final selected = scanners.firstWhere(
          (s) => s.id == selectedId,
          orElse: () => scanners.first,
        );
        return Tooltip(
          message: '${selected.name} (${selected.ip})',
          waitDuration: const Duration(milliseconds: 400),
          child: DropdownButtonFormField<String>(
            initialValue: selectedId,
            isExpanded: true,
            items: scanners.map((s) {
              return DropdownMenuItem(
                value: s.id,
                child: Text('${s.name} (${s.ip})',
                    overflow: TextOverflow.ellipsis),
              );
            }).toList(),
            onChanged: (val) {
              ref.read(selectedScannerIdProvider.notifier).setScannerId(val);
            },
          ),
        );
      },
      loading: () => const CircularProgressIndicator(),
      error: (err, stack) => Text(
        l10n.errorText(err.toString()),
        style: TextStyle(color: _scheme.error),
      ),
    );
  }

  /// Builds the DPI and color mode dropdowns based on scanner capabilities.
  Widget _buildCapabilitiesSettings(
    AsyncValue<Map<String, dynamic>> capsAsync,
  ) {
    final l10n = _l10n;
    return capsAsync.when(
      data: (caps) {
        final dpis = (caps['dpi'] as List<dynamic>?)?.cast<int>() ??
            [100, 150, 200, 300, 600];
        final colorModes =
            (caps['colorModes'] as List<dynamic>?)?.cast<String>() ??
                ['RGB24', 'Grayscale8'];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              initialValue: dpis.contains(_dpi) ? _dpi : dpis.first,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.resolutionDpi),
              items: dpis
                  .map((d) => DropdownMenuItem(value: d, child: Text('$d DPI')))
                  .toList(),
              onChanged: (val) {
                if (val != null) setState(() => _dpi = val);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: colorModes.contains(_colorMode)
                  ? _colorMode
                  : colorModes.first,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.colorMode),
              items: colorModes
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (val) {
                if (val != null) setState(() => _colorMode = val);
              },
            ),
          ],
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (_, __) => const SizedBox(),
    );
  }

  /// Builds the output format dropdown (JPEG/PDF) based on scanner
  /// capabilities. Only formats the scanner actually supports are shown.
  Widget _buildDocumentFormatDropdown(
    AsyncValue<Map<String, dynamic>> capsAsync,
  ) {
    final l10n = _l10n;
    return capsAsync.when(
      data: (caps) {
        final formats =
            (caps['documentFormats'] as List<dynamic>?)?.cast<String>() ??
                ['image/jpeg'];

        if (formats.length <= 1 && formats.first == 'image/jpeg') {
          // Scanner only supports JPEG — no need to show the dropdown
          return const SizedBox.shrink();
        }

        return DropdownButtonFormField<String>(
          initialValue: formats.contains(_documentFormat)
              ? _documentFormat
              : formats.first,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.outputFormat),
          items: formats.map((f) {
            final label = f == 'image/jpeg'
                ? l10n.jpegImage
                : f == 'application/pdf'
                    ? l10n.pdfDocument
                    : f;
            return DropdownMenuItem(value: f, child: Text(label));
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _documentFormat = val;
                // When switching to JPEG, reset the append target since
                // appending only makes sense for PDF.
                if (val != 'application/pdf') {
                  _targetPdfId = null;
                }
              });
            }
          },
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// Builds the document source (Platen/ADF) dropdown.
  Widget _buildSourceDropdown() {
    final l10n = _l10n;
    return DropdownButtonFormField<DocumentSource>(
      initialValue: _source,
      isExpanded: true,
      decoration: InputDecoration(labelText: l10n.source),
      items: [
        DropdownMenuItem(
            value: DocumentSource.platen,
            child: Text(l10n.flatbedPlaten, overflow: TextOverflow.ellipsis)),
        DropdownMenuItem(
            value: DocumentSource.adf,
            child:
                Text(l10n.documentFeederAdf, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (val) {
        if (val != null) setState(() => _source = val);
      },
    );
  }

  /// Builds the PDF append-target dropdown: "New PDF" plus every existing
  /// PDF, most recently modified first, with the just-created PDF
  /// pre-selected.
  Widget _buildPdfTargetDropdown() {
    final l10n = _l10n;
    final scansAsync = ref.watch(scansProvider);
    return scansAsync.when(
      data: (scans) {
        final pdfs =
            scans.where((s) => s.mimeType == 'application/pdf').toList();

        // If the selected PDF no longer exists (e.g. deleted in the
        // history), reset to "New PDF" to avoid an invalid dropdown value.
        final selectedId =
            _targetPdfId != null && pdfs.any((p) => p.id == _targetPdfId)
                ? _targetPdfId
                : null;
        if (selectedId == null && _targetPdfId != null) {
          Future.microtask(() => setState(() => _targetPdfId = null));
        }

        return DropdownButtonFormField<String?>(
          initialValue: selectedId,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.appendTo),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(l10n.newPdf, overflow: TextOverflow.ellipsis),
            ),
            for (final pdf in pdfs)
              DropdownMenuItem<String?>(
                value: pdf.id,
                child: Text(pdf.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (val) {
            setState(() => _targetPdfId = val);
          },
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// Renders a small info card showing the current crop region ratios.
  Widget _buildCropInfo(CropRegion cropRegion) {
    final l10n = _l10n;
    final scheme = _scheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.crop, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                l10n.crop,
                style: _textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () =>
                    ref.read(cropRegionProvider.notifier).setCropRegion(null),
                child:
                    Icon(Icons.close, size: 14, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'X: ${(cropRegion.xRatio * 100).toStringAsFixed(1)}%  '
            'Y: ${(cropRegion.yRatio * 100).toStringAsFixed(1)}%\n'
            'W: ${(cropRegion.widthRatio * 100).toStringAsFixed(1)}%  '
            'H: ${(cropRegion.heightRatio * 100).toStringAsFixed(1)}%',
            style: _textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// Builds the preview and final scan action buttons.
  Widget _buildActionButtons(
    String? selectedScannerId,
    CropRegion? cropRegion,
  ) {
    final l10n = _l10n;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.visibility),
            label: Text(l10n.previewScan),
            onPressed: _isScanning || selectedScannerId == null
                ? null
                : () => _triggerPreviewScan(selectedScannerId),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            icon: const Icon(Icons.document_scanner),
            label: Text(cropRegion != null ? l10n.scanCropRegion : l10n.scan),
            onPressed: _isScanning || selectedScannerId == null
                ? null
                : () => _triggerFinalScan(selectedScannerId),
          ),
        ),
      ],
    );
  }

  /// Builds the right preview area with status bar and image viewer.
  Widget _buildPreviewArea({
    required Uint8List? previewBytes,
    required String statusText,
    required bool isScanning,
    required CropRegion? cropRegion,
  }) {
    final l10n = _l10n;
    final scheme = _scheme;
    return Expanded(
      child: Container(
        color: scheme.surface,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Status bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  RotationTransition(
                    turns: _spinnerController,
                    child: Icon(
                      isScanning ? Icons.sync : Icons.info_outline,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.statusLabel(statusText),
                      style: _textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (previewBytes != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      l10n.dragCropHint,
                      style:
                          _textTheme.bodySmall?.copyWith(color: scheme.outline),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Preview image viewer with crop overlay
            Expanded(
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: previewBytes != null
                      ? Stack(
                          fit: StackFit.passthrough,
                          children: [
                            Image.memory(
                              previewBytes,
                              fit: BoxFit.contain,
                            ),
                            Positioned.fill(
                              child: CropOverlay(
                                initialCrop: cropRegion,
                                onCropChanged: (region) {
                                  ref
                                      .read(cropRegionProvider.notifier)
                                      .setCropRegion(region);
                                },
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.image_outlined,
                                size: 64, color: scheme.outline),
                            const SizedBox(height: 16),
                            Text(
                              l10n.clickPreviewHint,
                              style: _textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Triggers a preview scan at low resolution (100 DPI).
  Future<void> _triggerPreviewScan(String scannerId) async {
    final l10n = _l10n;
    setState(() => _isScanning = true);
    _spinnerController.repeat();
    ref.read(scanStatusProvider.notifier).setStatus(l10n.loadingPreview);
    // Reset crop when loading a new preview
    ref.read(cropRegionProvider.notifier).setCropRegion(null);

    try {
      final api = ref.read(apiServiceProvider);
      final config = ScanJobConfig(
        scannerId: scannerId,
        intent: ScanIntent.preview,
        source: _source,
        dpi: 100,
        colorMode: _colorMode,
        targetMode: TargetMode.newPdf,
        documentFormat: _documentFormat,
      );

      final bytes = await api.requestPreviewScan(config);
      ref.read(previewImageProvider.notifier).setImage(bytes);
      ref.read(scanStatusProvider.notifier).setStatus(l10n.previewReady);
    } catch (e) {
      ref
          .read(scanStatusProvider.notifier)
          .setStatus(l10n.previewError(e.toString()));
    } finally {
      _spinnerController.stop();
      _spinnerController.reset();
      setState(() => _isScanning = false);
    }
  }

  /// Triggers a final scan at the configured DPI.
  Future<void> _triggerFinalScan(String scannerId) async {
    final l10n = _l10n;
    final isPdf = _documentFormat == 'application/pdf';
    final appendTarget = isPdf ? _targetPdfId : null;

    setState(() => _isScanning = true);
    _spinnerController.repeat();
    final crop = ref.read(cropRegionProvider);
    ref.read(scanStatusProvider.notifier).setStatus(
        crop != null ? l10n.scanningCropRegion : l10n.scanningDocument);

    try {
      final api = ref.read(apiServiceProvider);
      final config = ScanJobConfig(
        scannerId: scannerId,
        intent: ScanIntent.finalScan,
        source: _source,
        dpi: _dpi,
        colorMode: _colorMode,
        crop: crop,
        targetMode:
            appendTarget == null ? TargetMode.newPdf : TargetMode.append,
        targetPdfId: appendTarget,
        documentFormat: _documentFormat,
      );

      final result = await api.triggerFinalScan(config);

      if (isPdf) {
        // Pre-select the just-created/appended PDF for the next scan.
        setState(() => _targetPdfId = result.scanId);
      }

      final name = result.scanName ?? (isPdf ? 'scan.pdf' : 'scan.jpg');
      ref.read(scanStatusProvider.notifier).setStatus(
            l10n.savedStatus(name, result.bytes.length.toString()),
          );

      // Show a toast (Material 3 SnackBar) with the saved file's name.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.saved(name))),
        );
      }

      // Refresh the history so the new file appears immediately.
      ref.invalidate(scansProvider);
    } catch (e) {
      ref
          .read(scanStatusProvider.notifier)
          .setStatus(l10n.scanError(e.toString()));
    } finally {
      _spinnerController.stop();
      _spinnerController.reset();
      setState(() => _isScanning = false);
    }
  }

  /// Builds the scan history view (replaces the scan/preview area).
  Widget _buildHistoryView() {
    final l10n = _l10n;
    final scheme = _scheme;
    final scansAsync = ref.watch(scansProvider);
    return Container(
      width: double.infinity,
      color: scheme.surface,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, color: scheme.primary),
              const SizedBox(width: 12),
              Text(l10n.scanHistory, style: _textTheme.titleLarge),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.refresh, color: scheme.onSurfaceVariant),
                onPressed: () => ref.invalidate(scansProvider),
                tooltip: l10n.refreshHistory,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: scansAsync.when(
              data: (scans) {
                if (scans.isEmpty) {
                  return Center(
                    child: Text(
                      l10n.noScansYet,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: scans.length,
                  separatorBuilder: (_, __) =>
                      Divider(color: scheme.outlineVariant),
                  itemBuilder: (context, index) =>
                      _buildHistoryItem(scans[index]),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text(
                  l10n.errorText(err.toString()),
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a single history row with open/download/delete actions.
  Widget _buildHistoryItem(ScannedFile file) {
    final l10n = _l10n;
    final scheme = _scheme;
    final api = ref.read(apiServiceProvider);
    final isPdf = file.mimeType == 'application/pdf';
    return ListTile(
      leading: Icon(
        isPdf ? Icons.picture_as_pdf : Icons.image,
        color: scheme.primary,
      ),
      title: Text(
        file.name,
        style: TextStyle(color: scheme.onSurface),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_formatBytes(file.sizeBytes)} · ${_formatDate(file.modifiedAt)}',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.open_in_new, color: scheme.primary),
            tooltip: l10n.openInBrowser,
            onPressed: () => _openScan(api, file),
          ),
          IconButton(
            icon: Icon(Icons.download, color: scheme.onSurfaceVariant),
            tooltip: l10n.download,
            onPressed: () => _downloadScan(api, file),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, color: scheme.error),
            tooltip: l10n.delete,
            onPressed: () => _deleteScan(api, file),
          ),
        ],
      ),
    );
  }

  /// Opens a stored file inline in a new browser tab.
  void _openScan(ApiService api, ScannedFile file) {
    web.window.open(api.scanFileUrl(file.id), '_blank');
  }

  /// Triggers a browser download of a stored file.
  void _downloadScan(ApiService api, ScannedFile file) {
    final anchor = web.HTMLAnchorElement()
      ..href = api.scanDownloadUrl(file.id)
      ..download = file.name;
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
  }

  /// Deletes a stored file and refreshes the history.
  Future<void> _deleteScan(ApiService api, ScannedFile file) async {
    final l10n = _l10n;
    try {
      await api.deleteScan(file.id);
      ref.invalidate(scansProvider);
      ref
          .read(scanStatusProvider.notifier)
          .setStatus(l10n.deletedStatus(file.name));
    } catch (e) {
      ref
          .read(scanStatusProvider.notifier)
          .setStatus(l10n.deleteError(e.toString()));
    }
  }

  /// Formats a byte count as a human-readable size (B/KB/MB/GB).
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Formats a timestamp as `yyyy-MM-dd HH:mm`.
  String _formatDate(DateTime dt) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${p2(dt.month)}-${p2(dt.day)} '
        '${p2(dt.hour)}:${p2(dt.minute)}';
  }
}
