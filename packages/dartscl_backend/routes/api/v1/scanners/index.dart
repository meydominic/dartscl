import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';

/// Handles GET /api/v1/scanners — returns cached scanner devices instantly.
///
/// Scanner discovery runs at server startup, so this endpoint does no
/// network I/O — it returns the cached device list immediately.
Future<Response> onRequest(RequestContext context) async {
  final registry = context.read<ScannerRegistry>();
  final scanners = registry.getScanners();

  return Response.json(body: scanners.map((s) => s.toJson()).toList());
}
