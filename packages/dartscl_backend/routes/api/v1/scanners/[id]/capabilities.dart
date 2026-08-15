import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/escl_client.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';

/// Handles GET /api/v1/scanners/[id]/capabilities — returns cached or
/// on-demand-fetched capabilities.
///
/// Capabilities are pre-fetched at server startup and cached, so this
/// endpoint typically returns instantly with no network I/O.
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
        body: {'error': 'Scanner not found'},
      );
    }

    // Fetch or get cached capabilities
    final caps = await registry.getCapabilities(id);

    return Response.json(
      body: {
        'scannerId': id,
        'makeAndModel': device.name,
        ...caps,
      },
    );
  } on EsclException catch (e) {
    if (e.isBusy) {
      return Response.json(
        statusCode: 503,
        body: {'error': 'scanner_busy', 'message': e.message},
      );
    }
    return Response.json(
      statusCode: 500,
      body: {'error': e.message},
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {'error': e.toString()},
    );
  }
}
