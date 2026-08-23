import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import 'package:dartscl_backend/src/scan_storage.dart';
import 'package:dartscl_backend/src/scanner_registry.dart';
import 'package:logging/logging.dart';

// ---------------------------------------------------------------------------
// Logging setup — routes all package:logging output to stdout so that
// Logger.info/warning/severe calls actually show up in the terminal.
// ---------------------------------------------------------------------------
// Lazy-init flag — ensures logging is set up exactly once.
bool _loggingInitialized = false;

void _initLogging() {
  if (_loggingInitialized) return;
  _loggingInitialized = true;

  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(
      '[${record.level.name}] ${record.loggerName}: ${record.message}',
    );
    if (record.error != null) {
      stdout.writeln('  └─ ${record.error}');
    }
    if (record.stackTrace != null) {
      stdout.writeln('     ${record.stackTrace}');
    }
  });
}

/// Logger for middleware.
final Logger _log = Logger('Middleware');

// Singleton instances held across the server lifecycle.
// Mock fallback is controlled via DARTSCL_USE_MOCK env var (default: on).
final _scannerRegistry = ScannerRegistry();

/// Persistent storage for scanned files. Configured via SCAN_STORAGE_PATH,
/// SCAN_MAX_STORAGE, SCAN_STORAGE_FULL_POLICY, SCAN_RETENTION_DAYS.
final _scanStorage = ScanStorage.fromEnvironment();

/// Resolves the base directory for static web assets.
///
/// The location of `static/` differs between run modes:
/// 1. **Working directory** — `dart run .dart_frog/server.dart` executed
///    from the package directory (`packages/dartscl_backend/static`).
/// 2. **AOT production binary** — `dart_frog build` copies `static/` next to
///    `bin/server.dart`, so `../static` relative to the server binary
///    resolves to `<build>/static`.
/// 3. **Script-relative** — covers invocations where the server is started
///    from a different working directory.
///
/// The first candidate that exists is used; if none exists, the AOT layout
/// (candidate 2) is assumed as a fallback.
Directory _resolveStaticBase() {
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final candidates = <Directory>[
    Directory('${Directory.current.path}/static'),
    Directory.fromUri(Platform.script.resolve('../static')),
    Directory('${scriptDir.path}/../static'),
  ];
  for (final candidate in candidates) {
    if (candidate.existsSync()) return candidate;
  }
  return candidates[1];
}

/// Base path for static web assets, resolved per run mode (see
/// [_resolveStaticBase]).
final _staticBase = _resolveStaticBase();

/// Mapping of file extensions to MIME types for static file serving.
const _mimeTypes = <String, String>{
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.wasm': 'application/wasm',
  '.map': 'application/json',
};

Handler middleware(Handler handler) {
  _initLogging();
  _log.info('Initializing middleware — ScannerRegistry singleton created.');
  _log.info('Static files base: ${_staticBase.path}');

  // Trigger scanner discovery + capability pre-fetch at startup so that
  // the Web UI gets instant responses on first load.
  unawaited(_scannerRegistry.initialize());

  return handler
      .use(provider<ScannerRegistry>((_) => _scannerRegistry))
      .use(provider<ScanStorage>((_) => _scanStorage))
      .use(_staticFilesMiddleware())
      .use(_corsMiddleware());
}

/// Middleware that serves static files from the `static/` directory.
///
/// Intercepts GET requests before they reach the API router and serves
/// matching files from `static/`. If the request path is `/` or maps to
/// a directory, `index.html` is served instead, enabling client-side
/// routing for the Flutter Web app.
Middleware _staticFilesMiddleware() {
  return (handler) {
    return (context) async {
      final request = context.request;
      if (request.method != HttpMethod.get) {
        return handler(context);
      }

      final requestPath = request.uri.path;

      // Never intercept API routes
      if (requestPath.startsWith('/api/')) {
        return handler(context);
      }

      // Resolve the requested file path
      var relativePath = requestPath;
      if (relativePath == '/' || relativePath.isEmpty) {
        relativePath = '/index.html';
      }
      // Strip leading slash, canonicalize away any `..`/`.` segments so a
      // crafted request can never escape the static base directory.
      final filePath = relativePath.startsWith('/')
          ? relativePath.substring(1)
          : relativePath;
      final normalizedSegments = <String>[];
      for (final segment in filePath.split('/')) {
        if (segment.isEmpty || segment == '.') continue;
        if (segment == '..') {
          if (normalizedSegments.isNotEmpty) normalizedSegments.removeLast();
          continue;
        }
        normalizedSegments.add(segment);
      }
      final safePath = normalizedSegments.join('/');
      final file = File('${_staticBase.path}/$safePath');

      if (await file.exists()) {
        final extension =
            safePath.contains('.') ? '.${safePath.split('.').last}' : '';
        final contentType = _mimeTypes[extension] ?? 'application/octet-stream';
        final body = await file.readAsBytes();

        return Response.bytes(
          body: body,
          headers: {
            'Content-Type': contentType,
            'Cache-Control': 'no-cache, no-store, must-revalidate',
          },
        );
      }

      // If the file doesn't exist but isn't an API route, serve index.html
      // for client-side routing (Flutter Web SPA fallback).
      if (!requestPath.contains('.')) {
        final indexFile = File('${_staticBase.path}/index.html');
        if (await indexFile.exists()) {
          final body = await indexFile.readAsBytes();
          return Response.bytes(
            body: body,
            headers: {
              'Content-Type': 'text/html; charset=utf-8',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
            },
          );
        }
      }

      return handler(context);
    };
  };
}

Middleware _corsMiddleware() {
  return (handler) {
    return (context) async {
      final request = context.request;
      if (request.method == HttpMethod.options) {
        return Response(
          statusCode: 204,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Authorization',
            'Access-Control-Max-Age': '86400',
          },
        );
      }

      final response = await handler(context);
      return response.copyWith(
        headers: {
          ...response.headers,
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        },
      );
    };
  };
}
