// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, implicit_dynamic_list_literal

import 'dart:io';

import 'package:dart_frog/dart_frog.dart';


import '../routes/api/v1/scan.dart' as api_v1_scan;
import '../routes/api/v1/scanners/index.dart' as api_v1_scanners_index;
import '../routes/api/v1/scanners/[id]/capabilities.dart' as api_v1_scanners_$id_capabilities;
import '../routes/api/v1/scans/index.dart' as api_v1_scans_index;
import '../routes/api/v1/scans/[id].dart' as api_v1_scans_$id;

import '../routes/_middleware.dart' as middleware;

void main() async {
  final address = InternetAddress.tryParse('') ?? InternetAddress.anyIPv6;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;
  hotReload(() => createServer(address, port));
}

Future<HttpServer> createServer(InternetAddress address, int port) {
  final handler = Cascade().add(buildRootHandler()).handler;
  return serve(handler, address, port);
}

Handler buildRootHandler() {
  final pipeline = const Pipeline().addMiddleware(middleware.middleware);
  final router = Router()
    ..mount('/api/v1', (context) => buildApiV1Handler()(context))
    ..mount('/api/v1/scanners', (context) => buildApiV1ScannersHandler()(context))
    ..mount('/api/v1/scanners/<id>', (context,id,) => buildApiV1Scanners$idHandler(id,)(context))
    ..mount('/api/v1/scans', (context) => buildApiV1ScansHandler()(context))
    ..mount('/api/v1/scans/<id>', (context,id,) => buildApiV1Scans$idHandler(id,)(context));
  return pipeline.addHandler(router);
}

Handler buildApiV1Handler() {
  final pipeline = const Pipeline();
  final router = Router()
    ..all('/scan', (context) => api_v1_scan.onRequest(context,));
  return pipeline.addHandler(router);
}

Handler buildApiV1ScannersHandler() {
  final pipeline = const Pipeline();
  final router = Router()
    ..all('/', (context) => api_v1_scanners_index.onRequest(context,));
  return pipeline.addHandler(router);
}

Handler buildApiV1Scanners$idHandler(String id,) {
  final pipeline = const Pipeline();
  final router = Router()
    ..all('/capabilities', (context) => api_v1_scanners_$id_capabilities.onRequest(context,id,));
  return pipeline.addHandler(router);
}

Handler buildApiV1ScansHandler() {
  final pipeline = const Pipeline();
  final router = Router()
    ..all('/', (context) => api_v1_scans_index.onRequest(context,));
  return pipeline.addHandler(router);
}

Handler buildApiV1Scans$idHandler(String id,) {
  final pipeline = const Pipeline();
  final router = Router()
    ..all('/', (context) => api_v1_scans_$id.onRequest(context,id,));
  return pipeline.addHandler(router);
}

