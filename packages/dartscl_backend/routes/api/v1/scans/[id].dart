// dart_frog path-parameter route: the `[id]` filename is a framework
// convention, not a Dart identifier.
// ignore_for_file: file_names

import 'package:dart_frog/dart_frog.dart';
import 'package:dartscl_backend/src/scan_storage.dart';

/// Handles GET and DELETE on /api/v1/scans/[id].
///
/// GET returns the file bytes inline (browser viewer) unless
/// `?download=1` is set, which forces a download. DELETE removes the file.
Future<Response> onRequest(RequestContext context, String id) async {
  final storage = context.read<ScanStorage>();
  final entry = storage.get(id);

  switch (context.request.method) {
    case HttpMethod.get:
      if (entry == null) {
        return Response.json(
          statusCode: 404,
          body: {'error': 'Scan not found'},
        );
      }
      final bytes = await storage.readBytes(id);
      final download = context.request.uri.queryParameters['download'] == '1';
      final disposition = download ? 'attachment' : 'inline';
      return Response.bytes(
        body: bytes,
        headers: {
          'Content-Type': entry.mimeType,
          'Content-Disposition': '$disposition; filename="${entry.name}"',
          'Content-Length': '${bytes.length}',
          'Cache-Control': 'no-cache',
        },
      );

    case HttpMethod.delete:
      final deleted = await storage.delete(id);
      if (!deleted) {
        return Response.json(
          statusCode: 404,
          body: {'error': 'Scan not found'},
        );
      }
      return Response(statusCode: 204);

    default:
      return Response(statusCode: 405);
  }
}
