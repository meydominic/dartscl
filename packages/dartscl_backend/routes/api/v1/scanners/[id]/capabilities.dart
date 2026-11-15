import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';
import 'package:logging/logging.dart';

/// Logger for the capabilities route.
final Logger _log = Logger('CapabilitiesRoute');

/// Handles GET /api/v1/scanners/[id]/capabilities — returns cached or
/// on-demand-fetched capabilities.
///
/// Capabilities are pre-fetched at server startup and cached, so this
/// endpoint typically returns instantly with no network I/O. When the scanner
/// cannot be reached, the response contains only `scannerId` and
/// `makeAndModel` — the UI then offers its defaults rather than failing the
/// whole page.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  try {
    final registry = context.read<ScannerRegistry>();

    // Sync device lookup from cache
    final device = registry.getDevice(id);

    if (device == null) {
      return Response.json(
        statusCode: 404,
        body: {'error': 'scanner_missing'},
      );
    }

    // Fetch or get cached capabilities. `getCapabilities` already handles its
    // own failures and returns an empty map, so there is no exception to map
    // here (the previous `on EsclException` block was unreachable).
    final caps = await registry.getCapabilities(id);
    if (caps.isEmpty) {
      _log.warning(
        'No capabilities available for $id — returning device info only.',
      );
    }

    return Response.json(
      body: {
        'scannerId': id,
        'makeAndModel': device.name,
        ...caps,
      },
    );
  } catch (e, stackTrace) {
    _log.severe('Failed to serve capabilities for $id.', e, stackTrace);
    return Response.json(
      statusCode: 500,
      body: {'error': 'capabilities_failed'},
    );
  }
}
