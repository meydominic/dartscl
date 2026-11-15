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

      // `pathSegments` are percent-decoded, so asset names containing escaped
      // characters resolve correctly (the raw path search missed them and fell
      // through to the SPA fallback).
      //
      // A decoded segment can still contain separators (`%2f`, `%5c`), so each
      // segment is split again and normalized part by part. Without that,
      // `GET /..%2f..%2fetc%2fpasswd` arrives as the single segment
      // `../../etc/passwd` and would escape the static root.
      final segments = <String>[];
      if (request.uri.pathSegments.isEmpty) {
        segments.add('index.html');
      } else {
        for (final rawSegment in request.uri.pathSegments) {
          for (final part in rawSegment.split(RegExp(r'[/\\]'))) {
            if (part.isEmpty || part == '.') continue;
            if (part == '..') {
              // Never let a request climb above the static root.
              if (segments.isEmpty) {
                return Response(statusCode: 404);
              }
              segments.removeLast();
              continue;
            }
            segments.add(part);
          }
        }
      }

      final safePath = segments.join('/');
      if (safePath.isNotEmpty) {
        final response = await _serveStaticFile(
          File('${_staticBase.path}/$safePath'),
          safePath,
          request,
        );
        if (response != null) return response;
      }

      // If the file doesn't exist but isn't an API route, serve index.html
      // for client-side routing (Flutter Web SPA fallback).
      if (!requestPath.contains('.')) {
        final response = await _serveStaticFile(
          File('${_staticBase.path}/index.html'),
          'index.html',
          request,
        );
        if (response != null) return response;
      }

      return handler(context);
    };
  };
}

/// Serves [file] when it exists, honouring conditional requests, and returns
/// `null` when it is missing.
///
/// The `ETag` is derived from size and modification time, so the browser
/// revalidates with a cheap 304 instead of re-downloading several megabytes of
/// bundle on every page load — while a rebuilt app is still picked up at once
/// (`Cache-Control: no-cache`, not a long max-age).
Future<Response?> _serveStaticFile(
  File file,
  String safePath,
  Request request,
) async {
  if (!await file.exists()) return null;

  final extension =
      safePath.contains('.') ? '.${safePath.split('.').last}' : '';
  final contentType = _mimeTypes[extension] ?? 'application/octet-stream';
  final stat = await file.stat();
  // The path is part of the validator: two assets can share size and mtime.
  final etag = '"${safePath.hashCode}-${stat.size}-'
      '${stat.modified.millisecondsSinceEpoch}"';
  final headers = <String, String>{
    'Content-Type': contentType,
    'Cache-Control': 'no-cache',
    'ETag': etag,
    'Last-Modified': HttpDate.format(stat.modified.toUtc()),
  };

  final ifNoneMatch = request.headers['if-none-match'];
  if (ifNoneMatch != null && _matchesEtag(ifNoneMatch, etag)) {
    return Response(statusCode: 304, headers: headers);
  }

  return Response.bytes(body: await file.readAsBytes(), headers: headers);
}

/// Returns `true` when the `If-None-Match` header value contains [etag].
///
/// Browsers send weak validators (`W/"..."`) and comma-separated lists, so a
/// plain `==` comparison would miss valid revalidations and resend the body.
bool _matchesEtag(String headerValue, String etag) {
  for (final raw in headerValue.split(',')) {
    final candidate = raw.trim();
    if (candidate == etag) return true;
    if (candidate.startsWith('W/') && candidate.substring(2) == etag) {
      return true;
    }
  }
  return false;
}

/// Cross-origin hosts allowed to call the API, from `DARTSCL_CORS_ORIGINS`
/// (comma-separated, e.g. `http://localhost:3000`).
///
/// Empty by default: the production deployment serves the UI and the API from
/// the same origin, where no CORS header is needed. A wildcard is never sent —
/// it would let any website the user visits read, download and delete every
/// stored scan on the LAN.
final Set<String> _allowedCorsOrigins = {
  for (final origin in (Platform.environment['DARTSCL_CORS_ORIGINS'] ?? '')
      .split(','))
    if (origin.trim().isNotEmpty) origin.trim(),
};

/// HTTP methods advertised to allowed cross-origin clients.
const String _corsMethods = 'GET, POST, DELETE, OPTIONS';

/// Request headers advertised to allowed cross-origin clients.
const String _corsHeaders = 'Content-Type, Authorization';

/// Response headers a cross-origin client may read.
const String _exposedHeaders =
    'X-Scan-Id, X-Scan-Name, Content-Disposition';

Middleware _corsMiddleware() {
  return (handler) {
    return (context) async {
      final origin = context.request.headers['origin'];
      final allowed = origin != null && _allowedCorsOrigins.contains(origin);

      if (context.request.method == HttpMethod.options) {
        // A preflight from an origin that is not allow-listed must not receive
        // CORS headers — the browser then blocks the actual request.
        return Response(
          statusCode: 204,
          headers: {
            'Vary': 'Origin',
            if (allowed) 'Access-Control-Allow-Origin': origin,
            if (allowed) 'Access-Control-Allow-Methods': _corsMethods,
            if (allowed) 'Access-Control-Allow-Headers': _corsHeaders,
            if (allowed) 'Access-Control-Max-Age': '86400',
          },
        );
      }

      final response = await handler(context);
      if (!allowed) {
        // `Vary` must be sent even without CORS headers, so a shared cache
        // cannot hand this response to an allow-listed origin later.
        return response.copyWith(
          headers: {...response.headers, 'Vary': 'Origin'},
        );
      }

      return response.copyWith(
        headers: {
          ...response.headers,
          'Access-Control-Allow-Origin': origin,
          'Access-Control-Allow-Methods': _corsMethods,
          'Access-Control-Allow-Headers': _corsHeaders,
          // Without this the browser hides X-Scan-Id/X-Scan-Name from a
          // cross-origin client, which silently breaks the append chain.
          'Access-Control-Expose-Headers': _exposedHeaders,
          'Vary': 'Origin',
        },
      );
    };
  };
}
