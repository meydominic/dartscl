import 'dart:io';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'escl_client.dart';
import 'mock_scanner_service.dart';
import 'scanner_discovery_service.dart';
import 'package:logging/logging.dart';

/// Logger for ScannerRegistry.
final Logger _log = Logger('ScannerRegistry');

/// Registry that manages scanner discovery and capabilities with caching.
///
/// Scanner discovery runs ONCE at server startup via [initialize()] and caches
/// the results. Capabilities are also pre-fetched at startup and cached, so
/// the Web UI gets instant responses without waiting for mDNS or eSCL queries.
///
/// Call [refreshScanners()] to trigger a manual re-discovery (e.g. from a
/// "Reload" button in the UI).
class ScannerRegistry {
  final ScannerDiscoveryService discoveryService;
  final EsclClient esclClient;

  /// Cached scanner devices, populated by [initialize()] or [refreshScanners()].
  final Map<String, ScannerDevice> _cachedDevices = {};

  /// Cached capabilities per scanner ID, populated at startup and on refresh.
  final Map<String, Map<String, dynamic>> _capabilitiesCache = {};

  /// Ensures [initialize()] runs exactly once.
  bool _initialized = false;

  /// Controls whether the registry falls back to mock scanners when
  /// mDNS discovery finds no devices. Set to `false` to disable mock fallback.
  final bool useMockFallback;

  ScannerRegistry({
    ScannerDiscoveryService? discoveryService,
    EsclClient? esclClient,
    bool? useMockFallback,
  })  : discoveryService = discoveryService ?? MdnsScannerDiscoveryService(),
        esclClient = esclClient ?? EsclClient(),
        useMockFallback = useMockFallback ??
            Platform.environment['DARTSCL_USE_MOCK']?.toLowerCase() != 'false';

  // ---------------------------------------------------------------------------
  // Startup / Refresh
  // ---------------------------------------------------------------------------

  /// Initializes the registry: runs mDNS discovery and pre-fetches
  /// capabilities for all discovered scanners. Call this once at server
  /// startup (e.g. from _middleware.dart).
  ///
  /// Subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _log.info('ScannerRegistry initializing — starting discovery...');
    await _doDiscovery();
    _log.info(
      'ScannerRegistry initialized: ${_cachedDevices.length} device(s) cached.',
    );
  }

  /// Forces a full re-discovery and re-fetch of capabilities.
  /// Use this when the user clicks "Reload scanners" in the UI.
  Future<List<ScannerDevice>> refreshScanners() async {
    _log.info('ScannerRegistry refresh — re-running discovery...');
    await _doDiscovery();
    _log.info(
      'ScannerRegistry refreshed: ${_cachedDevices.length} device(s) cached.',
    );
    return _cachedDevices.values.toList();
  }

  /// Internal: runs mDNS discovery, updates caches, pre-fetches capabilities.
  Future<void> _doDiscovery() async {
    _cachedDevices.clear();
    _capabilitiesCache.clear();

    final discovered = await discoveryService.discoverScanners();

    if (discovered.isEmpty) {
      if (useMockFallback) {
        _log.info('No mDNS devices found. Falling back to mock scanners.');
        for (final device in mockScannerService.scanners) {
          _cachedDevices[device.id] = device;
        }
      } else {
        _log.warning('No mDNS devices found and mock fallback is disabled.');
      }
    } else {
      _log.info('${discovered.length} real device(s) found via mDNS!');
      for (final device in discovered) {
        _cachedDevices[device.id] = device;
      }
    }

    // Pre-fetch capabilities for all real devices (not mocks).
    // This runs in the background so startup isn't delayed by slow scanners.
    // If a scanner is busy, its capabilities will be fetched on first demand.
    for (final device in _cachedDevices.values) {
      if (device.id.startsWith('mock-')) continue;
      _prefetchCapabilities(device);
    }
  }

  /// Background-pre-fetch capabilities for a single device.
  Future<void> _prefetchCapabilities(ScannerDevice device) async {
    try {
      final caps = await esclClient.fetchCapabilities(device);
      _capabilitiesCache[device.id] = caps;
      _log.fine('Capabilities cached for ${device.name} (${device.id}).');
    } catch (e) {
      _log.warning(
        'Pre-fetch capabilities failed for ${device.name}: $e '
        '(will fetch on demand).',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Sync reads (instant, no network I/O)
  // ---------------------------------------------------------------------------

  /// Returns the currently cached scanner devices — instant, no mDNS.
  /// The cache is populated at server startup by [initialize()].
  List<ScannerDevice> getScanners() => _cachedDevices.values.toList();

  /// Returns a specific device from cache, or `null` if not found.
  ScannerDevice? getDevice(String id) => _cachedDevices[id];

  /// Returns the cached capabilities for a scanner, or fetches them on demand
  /// if the cache is cold (e.g. because the pre-fetch failed at startup).
  Future<Map<String, dynamic>> getCapabilities(String scannerId) async {
    if (_capabilitiesCache.containsKey(scannerId)) {
      return _capabilitiesCache[scannerId]!;
    }
    // On-demand fetch
    final device = _cachedDevices[scannerId];
    if (device == null) return {};
    if (device.id.startsWith('mock-')) {
      return _mockCapabilities(device);
    }
    try {
      final caps = await esclClient.fetchCapabilities(device);
      _capabilitiesCache[scannerId] = caps;
      return caps;
    } catch (e) {
      _log.warning('On-demand capabilities fetch failed for $scannerId: $e');
      return {};
    }
  }

  /// Returns hardcoded capabilities for mock scanner devices.
  Map<String, dynamic> _mockCapabilities(ScannerDevice device) => {
        'dpi': [100, 200, 300, 600],
        'colorModes': ['RGB24', 'Grayscale8'],
        'sources': ['platen', 'adf'],
        'maxWidth': 2159,
        'maxHeight': 2983,
      };
}
