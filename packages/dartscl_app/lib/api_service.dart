import 'dart:convert';
import 'dart:typed_data';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Build-time override for the backend API base URL.
///
/// Set it with a dart-define, e.g.:
/// ```bash
/// flutter build web --dart-define=DARTSCL_API_BASE_URL=https://scanner.example.com
/// flutter run -d chrome --dart-define=DARTSCL_API_BASE_URL=http://192.168.1.50:8080
/// ```
/// When empty (default), [defaultApiBaseUrl] resolves the base URL at runtime.
const String _envApiBaseUrl = String.fromEnvironment('DARTSCL_API_BASE_URL');

/// Resolves the backend API base URL at runtime.
///
/// Priority:
/// 1. An explicit `DARTSCL_API_BASE_URL` dart-define (see [_envApiBaseUrl]).
/// 2. Same-origin (empty string → relative URLs) when the app is served by
///    the Dart Frog backend itself on port 8080 (production deployment).
/// 3. `http://localhost:8080` as the development fallback (e.g. when running
///    the app via `flutter run -d chrome` on its own dev server port).
String get defaultApiBaseUrl {
  if (_envApiBaseUrl.isNotEmpty) return _envApiBaseUrl;
  if (Uri.base.port == 8080) return '';
  return 'http://localhost:8080';
}

/// Service for communicating with the DartSCL Dart Frog backend API.
class ApiService {
  /// Base URL of the backend, without a trailing slash. An empty string
  /// means same-origin (relative URLs), which works when the app is served
  /// by the backend itself.
  final String baseUrl;
  final http.Client client;

  ApiService({
    String? baseUrl,
    http.Client? client,
  })  : baseUrl = baseUrl ?? defaultApiBaseUrl,
        client = client ?? http.Client();

  /// Fetches all discovered eSCL scanners from `GET /api/v1/scanners`.
  Future<List<ScannerDevice>> fetchScanners() async {
    final response = await client.get(Uri.parse('$baseUrl/api/v1/scanners'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load scanners: ${response.statusCode}');
    }
    final List<dynamic> jsonList = jsonDecode(response.body);
    return jsonList
        .map((j) => ScannerDevice.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Fetches capabilities for a target scanner from `GET /api/v1/scanners/[id]/capabilities`.
  Future<Map<String, dynamic>> fetchCapabilities(String scannerId) async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/v1/scanners/$scannerId/capabilities'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load capabilities: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Requests a preview scan JPEG stream from `POST /api/v1/scan`.
  Future<Uint8List> requestPreviewScan(ScanJobConfig config) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/v1/scan'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config.toJson()),
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Preview scan failed with status: ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  /// Triggers a final scan job from `POST /api/v1/scan`.
  ///
  /// Returns the raw response bytes (JPEG image or PDF document) together
  /// with the backend-generated scan ID (`X-Scan-Id` header), which the
  /// client must pass as [ScanJobConfig.targetPdfId] when appending to the
  /// same PDF in a subsequent scan.
  Future<ScanResult> triggerFinalScan(ScanJobConfig config) async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/v1/scan'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config.toJson()),
    );
    if (response.statusCode != 200) {
      throw Exception('Final scan job failed: ${response.statusCode}');
    }
    return ScanResult(
      bytes: response.bodyBytes,
      scanId: response.headers['x-scan-id'],
    );
  }
}

/// Result of a final scan request: the raw response bytes plus the
/// backend-generated scan ID used to chain append scans.
class ScanResult {
  final Uint8List bytes;

  /// Backend scan ID (`X-Scan-Id` header); null for non-PDF responses.
  final String? scanId;

  const ScanResult({required this.bytes, this.scanId});
}

// ---------------------------------------------------------------------------
// Riverpod providers
// ---------------------------------------------------------------------------

/// Provider for [ApiService] singleton instance.
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

/// Provider that fetches the list of discovered scanner devices.
final scannersProvider = FutureProvider<List<ScannerDevice>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  return api.fetchScanners();
});

// ---------------------------------------------------------------------------
// Riverpod 3.0 Notifiers (state holders)
// ---------------------------------------------------------------------------

/// Notifier that holds the currently selected scanner ID (nullable).
class SelectedScannerIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setScannerId(String? id) => state = id;
}

final selectedScannerIdProvider =
    NotifierProvider<SelectedScannerIdNotifier, String?>(
  SelectedScannerIdNotifier.new,
);

/// Provider that fetches capabilities for the currently selected scanner.
final capabilitiesProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final scannerId = ref.watch(selectedScannerIdProvider);
  if (scannerId == null) return {};
  final api = ref.watch(apiServiceProvider);
  return api.fetchCapabilities(scannerId);
});

/// Notifier that holds preview scan image bytes (nullable).
class PreviewImageNotifier extends Notifier<Uint8List?> {
  @override
  Uint8List? build() => null;

  void setImage(Uint8List? imageBytes) => state = imageBytes;
}

final previewImageProvider = NotifierProvider<PreviewImageNotifier, Uint8List?>(
  PreviewImageNotifier.new,
);

/// Notifier that holds the current scan status message.
class ScanStatusNotifier extends Notifier<String> {
  @override
  String build() => 'Ready';

  void setStatus(String status) => state = status;
}

final scanStatusProvider = NotifierProvider<ScanStatusNotifier, String>(
  ScanStatusNotifier.new,
);

/// Notifier that holds the current crop region (nullable).
class CropRegionNotifier extends Notifier<CropRegion?> {
  @override
  CropRegion? build() => null;

  void setCropRegion(CropRegion? cropRegion) => state = cropRegion;
}

final cropRegionProvider = NotifierProvider<CropRegionNotifier, CropRegion?>(
  CropRegionNotifier.new,
);
