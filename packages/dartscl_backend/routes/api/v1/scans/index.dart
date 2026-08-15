import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/scan_storage.dart';

/// Handles GET /api/v1/scans — returns metadata for all stored scans,
/// most recently modified first.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final storage = context.read<ScanStorage>();
  return Response.json(
    body: storage.list().map((f) => f.toJson()).toList(),
  );
}
