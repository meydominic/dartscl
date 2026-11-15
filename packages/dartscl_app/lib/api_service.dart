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

/// Timeout for metadata requests (scanner list, capabilities, history).
///
/// Without a timeout a stalled backend leaves the UI in a permanently
/// "scanning" state with every control disabled.
const Duration _metadataTimeout = Duration(seconds: 15);

/// Timeout for scan requests.
///
/// Generous, but still bounded: the backend caps a scan at ~5 minutes (1 min
/// stale-job cleanup + 3 min document polling + one retry), so a shorter client
/// timeout would report failure for a scan the server still completes and
/// stores — the UI would then retry and duplicate the page.
const Duration _scanTimeout = Duration(minutes: 7);

/// Error thrown when the backend answers with a non-2xx status.
///
/// Carries the machine-readable `error` code from the response body so the UI
/// can distinguish "scanner busy" from "storage full" instead of showing a bare
/// status number.
class ApiException implements Exception {
  /// HTTP status code returned by the backend.
  final int statusCode;

  /// Error code from the JSON body (`{"error": "..."}`), when present.
  final String? code;

  const ApiException(this.statusCode, {this.code});

  @override
  String toString() =>
      code == null ? 'HTTP $statusCode' : '$code (HTTP $statusCode)';
}

/// Builds an [ApiException] from a non-2xx [response].
///
/// Reads the backend's `{"error": "..."}` body when it is JSON; non-JSON error
/// bodies (proxy pages, HTML) are ignored rather than crashing the parser.
ApiException _errorFrom(http.Response response) {
  String? code;
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];
      if (error is String) code = error;
    }
  } on FormatException {
    // Not JSON — fall back to the status code alone.
  }
  return ApiException(response.statusCode, code: code);
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
    final response = await client
        .get(Uri.parse('$baseUrl/api/v1/scanners'))
        .timeout(_metadataTimeout);
    if (response.statusCode != 200) {
      throw _errorFrom(response);
    }
    final List<dynamic> jsonList = jsonDecode(response.body);
    return jsonList
        .map((j) => ScannerDevice.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Fetches capabilities for a target scanner from `GET /api/v1/scanners/[id]/capabilities`.
  Future<Map<String, dynamic>> fetchCapabilities(String scannerId) async {
    final response = await client
        .get(
          Uri.parse('$baseUrl/api/v1/scanners/$scannerId/capabilities'),
        )
        .timeout(_metadataTimeout);
    if (response.statusCode != 200) {
      throw _errorFrom(response);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Requests a preview scan JPEG stream from `POST /api/v1/scan`.
  Future<Uint8List> requestPreviewScan(ScanJobConfig config) async {
    final response = await client
        .post(
          Uri.parse('$baseUrl/api/v1/scan'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(config.toJson()),
        )
        .timeout(_scanTimeout);
    if (response.statusCode != 200) {
      throw _errorFrom(response);
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
    final response = await client
        .post(
          Uri.parse('$baseUrl/api/v1/scan'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(config.toJson()),
        )
        .timeout(_scanTimeout);
    if (response.statusCode != 200) {
      throw _errorFrom(response);
    }
    return ScanResult(
      bytes: response.bodyBytes,
      scanId: response.headers['x-scan-id'],
      scanName: response.headers['x-scan-name'],
    );
  }

  /// Fetches the stored scan history from `GET /api/v1/scans`.
  Future<List<ScannedFile>> fetchScans() async {
    final response = await client
        .get(Uri.parse('$baseUrl/api/v1/scans'))
        .timeout(_metadataTimeout);
    if (response.statusCode != 200) {
      throw _errorFrom(response);
    }
    final List<dynamic> jsonList = jsonDecode(response.body);
    return jsonList
        .map((j) => ScannedFile.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// URL of a stored file, for opening inline in a browser tab.
  String scanFileUrl(String id) => '$baseUrl/api/v1/scans/$id';

  /// URL of a stored file with `?download=1`, forcing a download.
  String scanDownloadUrl(String id) => '$baseUrl/api/v1/scans/$id?download=1';

  /// Deletes a stored file via `DELETE /api/v1/scans/[id]`.
  ///
  /// A 404 (already gone) is treated as success for idempotency.
  Future<void> deleteScan(String id) async {
    final response = await client
        .delete(Uri.parse('$baseUrl/api/v1/scans/$id'))
        .timeout(_metadataTimeout);
    // A 404 means the file is already gone — idempotent success.
    if (response.statusCode != 204 && response.statusCode != 404) {
      throw _errorFrom(response);
    }
  }
}

/// Result of a final scan request: the raw response bytes plus the
/// backend-generated scan ID and display name used to chain append scans
/// and to show a confirmation toast.
class ScanResult {
  final Uint8List bytes;

  /// Backend scan ID (`X-Scan-Id` header); null for non-PDF responses.
  final String? scanId;

  /// Display name of the stored file (`X-Scan-Name` header).
  final String? scanName;

  const ScanResult({required this.bytes, this.scanId, this.scanName});
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

/// Provider that fetches the stored scan history.
final scansProvider = FutureProvider<List<ScannedFile>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  return api.fetchScans();
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

/// Aspect ratio (width / height) of the current preview image.
///
/// The compact layout sizes the crop overlay from this, so the overlay covers
/// the painted page instead of a letterboxed 4:3 box — otherwise every crop
/// ratio is computed against the wrong rectangle.
class PreviewAspectNotifier extends Notifier<double?> {
  @override
  double? build() => null;

  void setAspect(double? aspect) => state = aspect;
}

final previewAspectProvider =
    NotifierProvider<PreviewAspectNotifier, double?>(
  PreviewAspectNotifier.new,
);

/// Notifier that holds the current scan status message.
///
/// Defaults to an empty string; the UI shows a localized "ready" text when
/// it is empty.
class ScanStatusNotifier extends Notifier<String> {
  @override
  String build() => '';

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
