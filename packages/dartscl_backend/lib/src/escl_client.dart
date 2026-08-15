import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

/// Logger for eSCL client communications.
final Logger _log = Logger('EsclClient');

/// Exception thrown when communication with an eSCL scanner fails.
class EsclException implements Exception {
  final String message;
  final int? statusCode;
  final bool isBusy;

  EsclException(this.message, {this.statusCode, this.isBusy = false});

  @override
  String toString() =>
      'EsclException: $message (statusCode: $statusCode, isBusy: $isBusy)';
}

/// Client for communicating with an eSCL hardware scanner via HTTP/XML.
///
/// All requests use a raw `dart:io` [HttpClient] instead of `package:http`:
/// some embedded scanner TLS stacks (confirmed: EPSON WF-C5790) silently
/// reject requests that go through the `package:http` IOClient wrapper, and
/// they also reject Dart's default User-Agent header and any `charset`
/// parameter on the Content-Type. Every request therefore goes through
/// [_rawRequest] with a curl User-Agent and an exact `text/xml` Content-Type.
class EsclClient {
  /// Tracks the last active job URL per scanner ID so we can cancel it
  /// before creating a new job (avoids HTTP 409 "job already exists").
  /// URLs are stored with the correct scheme (https) matching the device,
  /// not the raw HTTP URL from the Location header.
  final Map<String, String> _lastJobUrls = {};

  /// Performs a raw HTTP request against the scanner.
  ///
  /// Accepts self-signed certificates (required for most eSCL scanners),
  /// sends a curl User-Agent, and omits any charset parameter from the
  /// Content-Type — all three are required for EPSON scanner compatibility.
  /// Returns the status code, the raw response body, and normalized
  /// lower-case response headers.
  Future<({int statusCode, Uint8List body, Map<String, String> headers})>
      _rawRequest(
    String method,
    Uri uri, {
    String? xmlBody,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ioClient = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    try {
      final request = switch (method) {
        'POST' => await ioClient.postUrl(uri),
        'DELETE' => await ioClient.deleteUrl(uri),
        _ => await ioClient.getUrl(uri),
      };
      request.headers.set('User-Agent', 'curl/8.7.1');
      if (xmlBody != null) {
        request.headers.set('Content-Type', 'text/xml');
        request.contentLength = xmlBody.length;
        request.write(xmlBody);
      }
      final response = await request.close().timeout(timeout);
      final responseBytes = await consolidateHttpClientResponseBytes(response);
      final headers = <String, String>{};
      response.headers.forEach((key, values) {
        headers[key.toLowerCase()] = values.join(', ');
      });
      return (
        statusCode: response.statusCode,
        body: responseBytes,
        headers: headers,
      );
    } finally {
      ioClient.close(force: true);
    }
  }

  /// Builds base URL for scanner device.
  String _buildUrl(ScannerDevice device, String endpoint) {
    final scheme = device.isSecure ? 'https' : 'http';
    final basePath = device.path.endsWith('/')
        ? device.path.substring(0, device.path.length - 1)
        : device.path;
    final subEndpoint = endpoint.startsWith('/') ? endpoint : '/$endpoint';
    return '$scheme://${device.ip}:${device.port}$basePath$subEndpoint';
  }

  /// Reconstructs a job URL with the correct scheme/port matching [device].
  ///
  /// EPSON scanners return `http://IP/...` in the Location header, but the
  /// eSCL endpoint is only accessible via HTTPS (port 443). This method
  /// replaces the scheme and port with the device's actual values.
  String _buildJobUrl(ScannerDevice device, String locationUrl) {
    final uri = Uri.parse(locationUrl);
    final scheme = device.isSecure ? 'https' : 'http';
    return '$scheme://${device.ip}:${device.port}${uri.path}';
  }

  /// Fetches `/ScannerStatus` from the scanner and returns a list of job URIs
  /// that are currently in "Processing" state.
  ///
  /// These jobs need to be cancelled before a new scan can be initiated.
  Future<List<String>> fetchProcessingJobUris(ScannerDevice device) async {
    final url = _buildUrl(device, '/ScannerStatus');
    try {
      final response = await _rawRequest(
        'GET',
        Uri.parse(url),
      );
      if (response.statusCode != 200) return [];

      final document = XmlDocument.parse(utf8.decode(
        response.body,
        allowMalformed: true,
      ));
      final processingUris = <String>[];

      // Use wildcard + local name filter for namespace-agnostic matching.
      // The xml package's findAllElements(name) matches qualified names
      // (e.g. scan:JobInfo), not local names.
      for (final jobInfo in document
          .findAllElements('*')
          .where((e) => e.name.local == 'JobInfo')) {
        final stateElem = jobInfo
            .findAllElements('*')
            .where((e) => e.name.local == 'JobState')
            .firstOrNull;
        if (stateElem?.innerText.trim() == 'Processing') {
          final uriElem = jobInfo
              .findAllElements('*')
              .where((e) => e.name.local == 'JobUri')
              .firstOrNull;
          if (uriElem != null) {
            processingUris.add(uriElem.innerText.trim());
          }
        }
      }
      return processingUris;
    } catch (e) {
      _log.warning('Error fetching ScannerStatus: $e');
      return [];
    }
  }

  /// Cancels all "Processing" jobs on the scanner by checking ScannerStatus
  /// and sending DELETE to each one.
  ///
  /// EPSON scanners require NextDocument to be called before DELETE will
  /// succeed. This method first attempts NextDocument (which may return
  /// the image or 404/503), then sends DELETE to fully cancel the job.
  /// This prevents 503 errors caused by stale jobs from previous sessions.
  Future<void> cancelStaleJobs(ScannerDevice device) async {
    final processingUris = await fetchProcessingJobUris(device);
    if (processingUris.isEmpty) {
      _log.fine('No stale Processing jobs found on scanner.');
      return;
    }
    _log.info(
      'Found ${processingUris.length} stale Processing job(s). Cancelling...',
    );
    for (final uri in processingUris) {
      final fullUrl = _buildJobUrl(device, uri);
      // EPSON requires consuming NextDocument before DELETE succeeds.
      // Attempt to consume any remaining document (image data is discarded).
      await _consumeNextDocument(fullUrl);
      // Now send DELETE to cancel the job.
      await _cancelJobUrl(fullUrl);
    }
  }

  /// Attempts to consume the scanned document via NextDocument.
  ///
  /// EPSON scanners keep a job in "Processing" state even after the
  /// image has been retrieved. Calling NextDocument is required before
  /// DELETE will succeed. If the scanner is still scanning (503/404),
  /// this method returns without error after a brief polling attempt.
  Future<void> _consumeNextDocument(String jobUrl) async {
    final nextDocUrl =
        jobUrl.endsWith('/') ? '${jobUrl}NextDocument' : '$jobUrl/NextDocument';

    _log.info('Consuming NextDocument at $nextDocUrl for stale job cleanup');

    try {
      for (var attempt = 0; attempt < 30; attempt++) {
        final response = await _rawRequest(
          'GET',
          Uri.parse(nextDocUrl),
          timeout: const Duration(seconds: 30),
        );
        if (response.statusCode == 200) {
          _log.info('NextDocument consumed successfully (stale job drained).');
          return;
        }
        if (response.statusCode == 404 || response.statusCode == 503) {
          _log.fine(
            'NextDocument attempt $attempt: HTTP ${response.statusCode}',
          );
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        // Any other status — just return, DELETE may still work
        _log.warning(
          'NextDocument returned HTTP ${response.statusCode}, proceeding with DELETE anyway',
        );
        return;
      }
      _log.warning(
        'NextDocument did not return image within 30 polling attempts, proceeding with DELETE',
      );
    } catch (e) {
      // Stale-job cleanup must never break the actual scan — log and let
      // the DELETE attempt below decide.
      _log.warning('Error consuming NextDocument for stale job: $e');
    }
  }

  /// Cancels a previously created scan job by sending DELETE to its job URL.
  ///
  /// Returns `true` if the job was successfully cancelled (HTTP 200) or
  /// no longer exists (HTTP 404). Returns `false` if the scanner rejected
  /// the cancellation. Errors are logged but not thrown.
  Future<bool> cancelPreviousJob(ScannerDevice device) async {
    final jobUrl = _lastJobUrls[device.id];
    if (jobUrl == null) {
      _log.fine('No previous job URL known for ${device.id}, skipping cancel.');
      return true;
    }

    try {
      _log.info('Cancelling previous scan job at $jobUrl');
      final response = await _rawRequest(
        'DELETE',
        Uri.parse(jobUrl),
        timeout: const Duration(seconds: 5),
      );

      if (response.statusCode == 200 ||
          response.statusCode == 204 ||
          response.statusCode == 404) {
        _log.info('Previous job cancelled (HTTP ${response.statusCode}).');
        _lastJobUrls.remove(device.id);
        return true;
      }

      _log.warning(
        'Failed to cancel previous job (HTTP ${response.statusCode}): '
        '${utf8.decode(response.body, allowMalformed: true)}',
      );
      return false;
    } catch (e) {
      _log.warning('Error cancelling previous job: $e');
      return false;
    }
  }

  /// Fetches `/ScannerCapabilities` from target scanner and parses XML payload.
  Future<Map<String, dynamic>> fetchCapabilities(ScannerDevice device) async {
    final url = _buildUrl(device, '/ScannerCapabilities');
    try {
      final response = await _rawRequest(
        'GET',
        Uri.parse(url),
        timeout: const Duration(seconds: 5),
      );

      if (response.statusCode == 503) {
        throw EsclException(
          'Scanner is busy or warming up',
          statusCode: 503,
          isBusy: true,
        );
      }
      if (response.statusCode != 200) {
        throw EsclException(
          'Failed to fetch capabilities',
          statusCode: response.statusCode,
        );
      }

      return parseCapabilitiesXml(utf8.decode(
        response.body,
        allowMalformed: true,
      ));
    } catch (e) {
      if (e is EsclException) rethrow;
      _log.severe('Network error connecting to scanner at $url: $e');
      throw EsclException('Network error connecting to scanner: $e');
    }
  }

  /// Parses `ScannerCapabilities` XML document into normalized Map.
  ///
  /// Uses wildcard element searches (`findAllElements('*')` + local name filter)
  /// to handle namespace-prefixed elements correctly. The `xml` package's
  /// `findAllElements(name)` matches against the *qualified* name (e.g.
  /// `scan:ColorMode`), not just the local name (`ColorMode`), so we must
  /// search by wildcard and filter by `name.local` for namespace-agnostic
  /// matching.
  Map<String, dynamic> parseCapabilitiesXml(String xmlString) {
    final document = XmlDocument.parse(xmlString);

    // Helper: find all elements with a given local name, regardless of
    // namespace prefix (scan:, pwg:, or no prefix).
    Iterable<XmlElement> findByLocal(String localName) =>
        document.findAllElements('*').where((e) => e.name.local == localName);

    // --- DPI parsing ---
    final dpis = <int>{};
    for (final element in findByLocal('DiscreteResolution')) {
      final xRes = element
          .findElements('*')
          .where((e) => e.name.local == 'XResolution')
          .firstOrNull
          ?.innerText;
      if (xRes != null && int.tryParse(xRes.trim()) != null) {
        dpis.add(int.parse(xRes.trim()));
      }
    }
    if (dpis.isEmpty) {
      _log.warning(
          'No DPI values found in scanner capabilities, using defaults');
      dpis.addAll([100, 200, 300, 600, 1200]);
    }

    // --- Color modes parsing ---
    final colorModes = <String>{};
    for (final element in findByLocal('ColorMode')) {
      final mode = element.innerText.trim();
      if (mode.isNotEmpty) {
        colorModes.add(mode);
      }
    }
    if (colorModes.isEmpty) {
      _log.warning('No ColorMode values found, using defaults');
      colorModes.addAll(['RGB24', 'Grayscale8']);
    }

    // --- Sources parsing (Platen vs ADF) ---
    final sources = <String>{};

    final hasPlaten = findByLocal('Platen').isNotEmpty;

    final hasAdf = findByLocal('Adf').isNotEmpty ||
        findByLocal('AdfSimplexInputCaps').isNotEmpty ||
        findByLocal('AdfDuplexInputCaps').isNotEmpty;

    if (hasPlaten) sources.add('platen');
    if (hasAdf) sources.add('adf');

    if (sources.isEmpty) {
      _log.warning('No document sources found, defaulting to platen');
      sources.add('platen');
    }

    // --- Max dimensions parsing ---
    int maxWidth = 2159;
    int maxHeight = 2983;

    final maxWidthElem = findByLocal('MaxWidth').firstOrNull;
    if (maxWidthElem != null &&
        int.tryParse(maxWidthElem.innerText.trim()) != null) {
      maxWidth = int.parse(maxWidthElem.innerText.trim());
    }

    final maxHeightElem = findByLocal('MaxHeight').firstOrNull;
    if (maxHeightElem != null &&
        int.tryParse(maxHeightElem.innerText.trim()) != null) {
      maxHeight = int.parse(maxHeightElem.innerText.trim());
    }

    // --- Document formats parsing ---
    final documentFormats = <String>{};
    for (final elem in findByLocal('DocumentFormat')) {
      documentFormats.add(elem.innerText.trim());
    }
    if (documentFormats.isEmpty) {
      // Default — every eSCL scanner supports at least JPEG
      documentFormats.add('image/jpeg');
    }

    return {
      'dpi': dpis.toList()..sort(),
      'colorModes': colorModes.toList(),
      'sources': sources.toList(),
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
      'documentFormats': documentFormats.toList(),
    };
  }

  /// Triggers a ScanJob via XML payload sent to `/ScanJobs`.
  ///
  /// Uses raw `dart:io` [HttpClient] to handle the eSCL POST, as some
  /// scanner HTTPS implementations are incompatible with the `package:http`
  /// IOClient wrapper and return empty 409 responses for valid requests.
  Future<Uint8List> executeScanJob(
      ScannerDevice device, ScanJobConfig config) async {
    final uri = Uri.parse(_buildUrl(device, '/ScanJobs'));
    final xmlPayload = _buildScanJobXml(config);

    _log.info('Sending ScanJob payload to $uri');
    _log.fine('XML payload:\n$xmlPayload');

    // Cancel any stale jobs on the scanner (e.g. from a previous session
    // that was interrupted, or from a previous scan where the job cleanup
    // failed). EPSON scanners block new scan jobs while a job is in
    // "Processing" state, returning HTTP 503.
    await cancelStaleJobs(device);

    // Cancel any previously known job before creating a new one
    await cancelPreviousJob(device);

    return _doScanJobPost(uri, xmlPayload, device, config);
  }

  /// Performs the actual HTTP POST to create a scan job.
  ///
  /// Extracted as a separate method so it can be retried (e.g. after
  /// cleaning up stale jobs on 503).
  Future<Uint8List> _doScanJobPost(
    Uri uri,
    String xmlPayload,
    ScannerDevice device,
    ScanJobConfig config, {
    bool isRetry = false,
  }) async {
    final response = await _rawRequest('POST', uri, xmlBody: xmlPayload);
    final statusCode = response.statusCode;
    final responseHeaders = response.headers;
    final responseBytes = response.body;

    // HTTP 409 = scanner already has a conflicting job
    // The eSCL spec says the conflicting job URL is in the response *body*,
    // but some scanners also return it in the Location *header*.
    final responseBodyStr = utf8.decode(responseBytes, allowMalformed: true);

    if (statusCode == 409) {
      _log.warning(
        'Scanner returned 409. Response headers: $responseHeaders\n'
        'Response body (first 2KB): ${responseBodyStr.length > 2048 ? responseBodyStr.substring(0, 2048) : responseBodyStr}',
      );

      // Try Location header first (some scanners use this)
      var conflictUrl = responseHeaders['location'];

      // If not in header, try to parse the response body as XML for a job URL
      if (conflictUrl == null || conflictUrl.isEmpty) {
        if (responseBodyStr.isNotEmpty) {
          try {
            final bodyXml = XmlDocument.parse(responseBodyStr);
            for (final elem in bodyXml.findAllElements('*')) {
              final text = elem.innerText.trim();
              if (text.startsWith('http://') ||
                  text.startsWith('https://') ||
                  text.startsWith('/')) {
                conflictUrl = text;
                _log.info('Extracted job URL from 409 body XML: $conflictUrl');
                break;
              }
            }
          } catch (_) {
            _log.info(
                '409 body is not parseable XML: "${responseBodyStr.length > 500 ? responseBodyStr.substring(0, 500) : responseBodyStr}"');
          }
        } else {
          _log.info(
              '409 body is empty — scanner rejected the request, no job conflict info available.');
        }
      }

      // Cancel the conflicting job if we found one, then retry once
      if (conflictUrl != null && conflictUrl.isNotEmpty) {
        _log.info('Attempting to cancel conflicting job at: $conflictUrl');
        await _cancelJobUrl(conflictUrl);
      }

      // Retry once
      final retryResponse = await _rawRequest('POST', uri, xmlBody: xmlPayload);
      final retryStatus = retryResponse.statusCode;
      final retryBytes = retryResponse.body;
      final retryHeaders = retryResponse.headers;

      if (retryStatus == 409) {
        final retryBodyStr = utf8.decode(retryBytes, allowMalformed: true);
        _log.severe(
          'Retry still got 409. Body: ${retryBodyStr.length > 2048 ? retryBodyStr.substring(0, 2048) : retryBodyStr}',
        );
        throw EsclException(
          'Scanner rejected scan job (HTTP 409). Response body: '
          '${retryBodyStr.length > 500 ? retryBodyStr.substring(0, 500) : retryBodyStr}',
          statusCode: 409,
          isBusy: true,
        );
      }

      return _handleJobResponse(
        retryStatus,
        retryBytes,
        retryHeaders,
        uri.toString(),
        device,
        config,
      );
    }

    if (statusCode == 503) {
      if (isRetry) {
        // Second attempt also got 503 — give up.
        throw EsclException('Scanner is busy', statusCode: 503, isBusy: true);
      }
      _log.warning(
        'Scanner returned 503 on first attempt. Trying stale job cleanup...',
      );
      // Check for stale Processing jobs that might be blocking the scan
      await cancelStaleJobs(device);
      // EPSON scanners need a brief cooldown (~3s) after cancelling a job
      // before they accept new scan jobs (otherwise they return 503).
      await Future.delayed(const Duration(seconds: 3));
      // Retry once after cleanup
      return _doScanJobPost(
        uri,
        xmlPayload,
        device,
        config,
        isRetry: true,
      );
    }
    if (statusCode != 201 && statusCode != 200) {
      _log.warning(
        'Scan job failed (HTTP $statusCode): $responseBodyStr',
      );
      throw EsclException(
        'Failed to create scan job (HTTP $statusCode): $responseBodyStr',
        statusCode: statusCode,
      );
    }

    return _handleJobResponse(
      statusCode,
      responseBytes,
      responseHeaders,
      uri.toString(),
      device,
      config,
    );
  }

  /// Cancels a specific job URL by sending an HTTP DELETE.
  ///
  /// Returns `true` if the cancellation was accepted (HTTP 200/204) or the
  /// job no longer exists (HTTP 404). Errors are logged but not rethrown.
  Future<bool> _cancelJobUrl(String url) async {
    try {
      _log.info('Sending DELETE to $url');
      final response = await _rawRequest(
        'DELETE',
        Uri.parse(url),
        timeout: const Duration(seconds: 5),
      );

      if (response.statusCode == 200 ||
          response.statusCode == 204 ||
          response.statusCode == 404) {
        _log.info('Job cancelled successfully (HTTP ${response.statusCode}).');
        return true;
      }
      _log.warning(
        'Failed to cancel job at $url (HTTP ${response.statusCode}): '
        '${utf8.decode(response.body, allowMalformed: true)}',
      );
      return false;
    } catch (e) {
      _log.warning('Error cancelling job at $url: $e');
      return false;
    }
  }

  /// Processes a successful job creation response: retrieves the scanned
  /// document via `NextDocument` and tracks the job URL for later cleanup.
  ///
  /// The scanner needs time to physically scan the document, so this method
  /// polls the `NextDocument` endpoint with a 1-second delay between attempts
  /// (up to 30 retries / ~30 seconds).
  Future<Uint8List> _handleJobResponse(
    int statusCode,
    Uint8List responseBytes,
    Map<String, String> responseHeaders,
    String scanJobsUrl,
    ScannerDevice device,
    ScanJobConfig config,
  ) async {
    final jobLocation = responseHeaders['location'];
    if (jobLocation == null || jobLocation.isEmpty) {
      throw EsclException('Scanner did not return Job Location header');
    }

    // Convert the Location URL (often HTTP from EPSON) to the correct
    // scheme/port matching the device (usually HTTPS port 443).
    final jobUrl = _buildJobUrl(device, jobLocation);

    // Track job URL so we can cancel it before the next scan
    _lastJobUrls[device.id] = jobUrl;

    final nextDocUrl =
        jobUrl.endsWith('/') ? '${jobUrl}NextDocument' : '$jobUrl/NextDocument';

    _log.info('Polling scanned document from $nextDocUrl');

    for (var attempt = 0; attempt < 60; attempt++) {
      final getResponse = await _rawRequest(
        'GET',
        Uri.parse(nextDocUrl),
        timeout: const Duration(seconds: 30),
      );

      if (getResponse.statusCode == 200) {
        // Job is consumed — remove from tracking
        _lastJobUrls.remove(device.id);

        final result = getResponse.body;
        _log.info(
          'Scan job completed successfully (${result.length} bytes, '
          '$attempt retries)',
        );

        // EPSON scanners keep the job in "Processing" state even after
        // NextDocument returns the image. Explicitly send DELETE to
        // cancel the job so subsequent scan attempts don't get 503.
        await _cancelJobUrl(jobUrl);
        _log.info('Scan job cleaned up via DELETE.');

        return result;
      }

      _log.fine(
        'NextDocument attempt $attempt: HTTP ${getResponse.statusCode}',
      );

      if (getResponse.statusCode == 404 || getResponse.statusCode == 503) {
        // Scanner is still scanning — wait and retry
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      // Unexpected status — fail immediately
      throw EsclException(
        'Failed to retrieve scanned document (HTTP ${getResponse.statusCode})',
        statusCode: getResponse.statusCode,
      );
    }

    throw EsclException(
      'NextDocument did not return image within 60 polling attempts',
    );
  }

  /// Reads all bytes from an [HttpClientResponse] into a single [Uint8List].
  static Future<Uint8List> consolidateHttpClientResponseBytes(
    HttpClientResponse response,
  ) async {
    final chunks = <List<int>>[];
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    if (chunks.length == 1) return Uint8List.fromList(chunks.first);
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final result = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  String _buildScanJobXml(ScanJobConfig config) {
    final sourceStr = config.source == DocumentSource.adf ? 'Feeder' : 'Platen';

    // EPSON WF-C5790 only accepts the "Preview" ScanIntent (returns 409
    // for "Document" and 503 for "TextAndGraphic"/"Photo"). Using Preview
    // is safe — the scan resolution is controlled by XResolution/
    // YResolution, not by the intent hint.
    const intentStr = 'Preview';

    // The scanner always delivers JPEG via eSCL — even when the user
    // requests PDF output. PDF conversion is done on the backend.
    const format = 'image/jpeg';

    return '''<?xml version="1.0" encoding="utf-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.0</pwg:Version>
  <pwg:ScanIntent>$intentStr</pwg:ScanIntent>
  <scan:InputSource>$sourceStr</scan:InputSource>
  <scan:ColorMode>${config.colorMode}</scan:ColorMode>
  <scan:XResolution>${config.dpi}</scan:XResolution>
  <scan:YResolution>${config.dpi}</scan:YResolution>
  <scan:DocumentFormatExt>$format</scan:DocumentFormatExt>
</scan:ScanSettings>''';
  }
}
