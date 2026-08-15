import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'api_service.dart';
import 'crop_overlay.dart';

void main() {
  runApp(
    const ProviderScope(
      child: DartSclWebApp(),
    ),
  );
}

/// Root widget of the DartSCL Web Scanner application.
///
/// Sets up the Material theme with a dark color scheme and Inter/Outfit
/// typography via Google Fonts.
class DartSclWebApp extends StatelessWidget {
  const DartSclWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DartSCL AirScan Web',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          surface: Color(0xFF1E293B),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      home: const MainScanScreen(),
    );
  }
}

/// Main scan screen with a left sidebar for controls and a right preview area.
///
/// The sidebar provides scanner selection, scan configuration (DPI, color mode,
/// source, target mode), crop info display, and action buttons. The right area
/// shows a preview image with an interactive crop overlay.
class MainScanScreen extends ConsumerStatefulWidget {
  const MainScanScreen({super.key});

  @override
  ConsumerState<MainScanScreen> createState() => _MainScanScreenState();
}

class _MainScanScreenState extends ConsumerState<MainScanScreen> {
  int _dpi = 300;
  String _colorMode = 'RGB24';
  String _documentFormat = 'image/jpeg';
  DocumentSource _source = DocumentSource.platen;
  TargetMode _targetMode = TargetMode.newPdf;
  bool _isScanning = false;

  /// Scan ID of the last PDF produced by this backend, required as
  /// `targetPdfId` when appending to that PDF in a subsequent scan.
  String? _lastPdfId;

  @override
  Widget build(BuildContext context) {
    final scannersAsync = ref.watch(scannersProvider);
    final selectedScannerId = ref.watch(selectedScannerIdProvider);
    final capsAsync = ref.watch(capabilitiesProvider);
    final previewBytes = ref.watch(previewImageProvider);
    final statusText = ref.watch(scanStatusProvider);
    final cropRegion = ref.watch(cropRegionProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.scanner, color: Color(0xFF38BDF8)),
            const SizedBox(width: 12),
            Text(
              'DartSCL Web Scanner',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.refresh(scannersProvider),
            tooltip: 'Reload scanners',
          ),
        ],
      ),
      body: Row(
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
            statusText: statusText,
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
    return Container(
      width: 340,
      color: const Color(0xFF1E293B),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('SCANNER SELECTION'),
          const SizedBox(height: 10),
          _buildScannerSelector(scannersAsync, selectedScannerId),
          const SizedBox(height: 24),
          _sectionLabel('SETTINGS'),
          const SizedBox(height: 12),
          _buildCapabilitiesSettings(capsAsync),
          const SizedBox(height: 12),
          _buildDocumentFormatDropdown(capsAsync),
          const SizedBox(height: 12),
          _buildSourceDropdown(),
          // Only show target mode when PDF output is selected
          if (_documentFormat == 'application/pdf') ...[
            const SizedBox(height: 12),
            _buildTargetModeDropdown(),
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
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: const Color(0xFF94A3B8),
        letterSpacing: 1.2,
      ),
    );
  }

  /// Builds the scanner selection dropdown.
  Widget _buildScannerSelector(
    AsyncValue<List<ScannerDevice>> scannersAsync,
    String? selectedScannerId,
  ) {
    return scannersAsync.when(
      data: (scanners) {
        if (scanners.isEmpty) {
          return const Text('No scanners found.');
        }
        if (selectedScannerId == null && scanners.isNotEmpty) {
          Future.microtask(() {
            ref
                .read(selectedScannerIdProvider.notifier)
                .setScannerId(scanners.first.id);
          });
        }
        return DropdownButtonFormField<String>(
          initialValue: selectedScannerId ?? scanners.first.id,
          isExpanded: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0F172A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          items: scanners.map((s) {
            return DropdownMenuItem(
              value: s.id,
              child:
                  Text('${s.name} (${s.ip})', overflow: TextOverflow.ellipsis),
            );
          }).toList(),
          onChanged: (val) {
            ref.read(selectedScannerIdProvider.notifier).setScannerId(val);
          },
        );
      },
      loading: () => const CircularProgressIndicator(),
      error: (err, stack) =>
          Text('Error: $err', style: const TextStyle(color: Colors.redAccent)),
    );
  }

  /// Builds the DPI and color mode dropdowns based on scanner capabilities.
  Widget _buildCapabilitiesSettings(
    AsyncValue<Map<String, dynamic>> capsAsync,
  ) {
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
              decoration: const InputDecoration(labelText: 'Resolution (DPI)'),
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
              decoration: const InputDecoration(labelText: 'Color mode'),
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
          decoration: const InputDecoration(labelText: 'Output format'),
          items: formats.map((f) {
            final label = f == 'image/jpeg'
                ? 'JPEG image'
                : f == 'application/pdf'
                    ? 'PDF document'
                    : f;
            return DropdownMenuItem(value: f, child: Text(label));
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _documentFormat = val;
                // When switching to JPEG, reset target mode to newPdf
                // since append only makes sense for PDF
                if (val != 'application/pdf') {
                  _targetMode = TargetMode.newPdf;
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
    return DropdownButtonFormField<DocumentSource>(
      initialValue: _source,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Source'),
      items: const [
        DropdownMenuItem(
            value: DocumentSource.platen,
            child: Text('Flatbed (Platen)', overflow: TextOverflow.ellipsis)),
        DropdownMenuItem(
            value: DocumentSource.adf,
            child:
                Text('Document Feeder (ADF)', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (val) {
        if (val != null) setState(() => _source = val);
      },
    );
  }

  /// Builds the target mode (new PDF / append) dropdown.
  Widget _buildTargetModeDropdown() {
    return DropdownButtonFormField<TargetMode>(
      initialValue: _targetMode,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Target mode'),
      items: [
        const DropdownMenuItem(
            value: TargetMode.newPdf,
            child: Text('Create new PDF', overflow: TextOverflow.ellipsis)),
        DropdownMenuItem(
            value: TargetMode.append,
            enabled: _lastPdfId != null,
            child:
                const Text('Append to PDF', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (val) {
        if (val != null) setState(() => _targetMode = val);
      },
    );
  }

  /// Renders a small info card showing the current crop region ratios.
  Widget _buildCropInfo(CropRegion cropRegion) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF38BDF8), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.crop, size: 14, color: Color(0xFF38BDF8)),
              const SizedBox(width: 6),
              Text(
                'CROP',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF94A3B8),
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () =>
                    ref.read(cropRegionProvider.notifier).setCropRegion(null),
                child:
                    const Icon(Icons.close, size: 14, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'X: ${(cropRegion.xRatio * 100).toStringAsFixed(1)}%  '
            'Y: ${(cropRegion.yRatio * 100).toStringAsFixed(1)}%\n'
            'W: ${(cropRegion.widthRatio * 100).toStringAsFixed(1)}%  '
            'H: ${(cropRegion.heightRatio * 100).toStringAsFixed(1)}%',
            style: GoogleFonts.inter(
                fontSize: 12, color: Colors.white70, height: 1.5),
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
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF38BDF8)),
            ),
            icon: const Icon(Icons.visibility),
            label: const Text('Preview scan'),
            onPressed: _isScanning || selectedScannerId == null
                ? null
                : () => _triggerPreviewScan(selectedScannerId),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF38BDF8),
              foregroundColor: const Color(0xFF0F172A),
            ),
            icon: const Icon(Icons.document_scanner),
            label: Text(
              cropRegion != null ? 'Scan crop region' : 'Scan',
              style: GoogleFonts.inter(fontWeight: FontWeight.bold),
            ),
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
    return Expanded(
      child: Container(
        color: const Color(0xFF0F172A),
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Status bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    isScanning ? Icons.sync : Icons.info_outline,
                    size: 18,
                    color: const Color(0xFF38BDF8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Status: $statusText',
                      style: GoogleFonts.inter(
                          fontSize: 14, color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (previewBytes != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      'Drag a rectangle on the image to select a crop region',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: const Color(0xFF64748B)),
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
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF334155)),
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
                            const Icon(Icons.image_outlined,
                                size: 64, color: Color(0xFF64748B)),
                            const SizedBox(height: 16),
                            Text(
                              'Click "Preview scan" to load the image',
                              style: GoogleFonts.inter(
                                  color: const Color(0xFF94A3B8)),
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

  /// Triggers a browser file download via blob URL (Web only).
  void _downloadBytes(Uint8List bytes, String mimeType, String filename) {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }

  /// Triggers a preview scan at low resolution (100 DPI).
  Future<void> _triggerPreviewScan(String scannerId) async {
    setState(() => _isScanning = true);
    ref.read(scanStatusProvider.notifier).setStatus('Loading preview...');
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
        targetMode: _targetMode,
        documentFormat: _documentFormat,
      );

      final bytes = await api.requestPreviewScan(config);
      ref.read(previewImageProvider.notifier).setImage(bytes);
      ref
          .read(scanStatusProvider.notifier)
          .setStatus('Preview ready — select a crop region or scan directly.');
    } catch (e) {
      ref.read(scanStatusProvider.notifier).setStatus('Preview error: $e');
    } finally {
      setState(() => _isScanning = false);
    }
  }

  /// Triggers a final scan at the configured DPI.
  Future<void> _triggerFinalScan(String scannerId) async {
    // Appending requires a PDF produced earlier in this session.
    if (_targetMode == TargetMode.append && _lastPdfId == null) {
      ref.read(scanStatusProvider.notifier).setStatus(
            'Create a new PDF first — append needs a previous scan.',
          );
      return;
    }

    setState(() => _isScanning = true);
    final crop = ref.read(cropRegionProvider);
    ref.read(scanStatusProvider.notifier).setStatus(
        crop != null ? 'Scanning crop region...' : 'Scanning document...');

    try {
      final api = ref.read(apiServiceProvider);
      final config = ScanJobConfig(
        scannerId: scannerId,
        intent: ScanIntent.finalScan,
        source: _source,
        dpi: _dpi,
        colorMode: _colorMode,
        crop: crop,
        targetMode: _targetMode,
        targetPdfId: _targetMode == TargetMode.append ? _lastPdfId : null,
        documentFormat: _documentFormat,
      );

      final result = await api.triggerFinalScan(config);
      final isPdf = _documentFormat == 'application/pdf';

      if (isPdf) {
        // Remember the stable scan ID so a subsequent append scan can
        // chain onto the PDF the backend just persisted.
        _lastPdfId = result.scanId ?? _lastPdfId;
      }

      final mimeType = isPdf ? 'application/pdf' : 'image/jpeg';
      final extension = isPdf ? 'pdf' : 'jpg';
      ref.read(scanStatusProvider.notifier).setStatus(
            '${extension.toUpperCase()} ready (${result.bytes.length} bytes) — download starting...',
          );
      // Trigger browser download via blob URL
      _downloadBytes(
        result.bytes,
        mimeType,
        'scan-${DateTime.now().millisecondsSinceEpoch}.$extension',
      );
    } catch (e) {
      ref.read(scanStatusProvider.notifier).setStatus('Scan error: $e');
    } finally {
      setState(() => _isScanning = false);
    }
  }
}
