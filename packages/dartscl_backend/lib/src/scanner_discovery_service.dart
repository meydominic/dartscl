import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:logging/logging.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'mdns_txt_parser.dart';

/// Logger for mDNS scanner discovery.
final Logger _log = Logger('MdnsScannerDiscovery');

/// Abstract interface for scanner discovery service.
abstract class ScannerDiscoveryService {
  /// Discovers active eSCL scanners on the local network.
  Future<List<ScannerDevice>> discoverScanners();
}

/// Production implementation of mDNS scanner discovery service.
class MdnsScannerDiscoveryService implements ScannerDiscoveryService {
  static const String _uscanService = '_uscan._tcp.local';
  static const String _uscansService = '_uscans._tcp.local';

  final MDnsClient _mdnsClient;

  MdnsScannerDiscoveryService({MDnsClient? mdnsClient})
      : _mdnsClient = mdnsClient ?? MDnsClient();

  @override
  Future<List<ScannerDevice>> discoverScanners() async {
    final devices = <String, ScannerDevice>{};

    _log.info('Starting mDNS Scanner Discovery...');

    try {
      await _mdnsClient.start();
      _log.info('MDnsClient started successfully.');

      // Discover plain HTTP eSCL (_uscan._tcp.local)
      _log.info('Querying service: $_uscanService (HTTP)...');
      await _queryService(_uscanService, isSecure: false, devices: devices);

      // Discover secure HTTPS eSCL (_uscans._tcp.local)
      _log.info('Querying service: $_uscansService (HTTPS)...');
      await _queryService(_uscansService, isSecure: true, devices: devices);
    } catch (e, stack) {
      _log.severe('Error during mDNS discovery: $e');
      _log.fine(stack.toString());
    } finally {
      _mdnsClient.stop();
      _log.info('MDnsClient stopped.');
    }

    _log.info(
      'Discovery complete. ${devices.length} device(s) found: ${devices.keys.toList()}',
    );
    return devices.values.toList();
  }

  Future<void> _queryService(
    String serviceName, {
    required bool isSecure,
    required Map<String, ScannerDevice> devices,
  }) async {
    // 1. Collect all available pointers on the network
    _log.info('Querying PTR records for $serviceName...');
    final ptrs = await _mdnsClient
        .lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(serviceName),
          timeout: const Duration(seconds: 3),
        )
        .toList();

    _log.info('${ptrs.length} PTR record(s) found for $serviceName.');

    for (final ptr in ptrs) {
      final domainName = ptr.domainName;
      _log.info('Processing PTR domain: $domainName');

      // 2. Query SRV & TXT records in parallel
      _log.info('Requesting SRV and TXT records for $domainName...');
      final srvFuture = _firstOrNull(
        _mdnsClient.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(domainName),
          timeout: const Duration(seconds: 2),
        ),
      );

      final txtFuture = _mdnsClient
          .lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(domainName),
            timeout: const Duration(seconds: 2),
          )
          .toList();

      final results = await Future.wait([srvFuture, txtFuture]);

      final srv = results[0] as SrvResourceRecord?;
      final txtRecords = results[1] as List<TxtResourceRecord>? ?? [];

      if (srv == null) {
        _log.warning(
          'Could not resolve SRV record for $domainName. Skipping.',
        );
        continue;
      }

      final targetHost = srv.target;
      final port = srv.port;
      _log.info('SRV resolved -> Host: $targetHost, Port: $port');

      final txtMap = <String, String>{};
      for (final txt in txtRecords) {
        txtMap.addAll(MdnsTxtParser.parseTxtString(txt.text));
      }
      _log.fine('TXT records parsed for $domainName: $txtMap');

      // 3. Resolve target host to IP address
      _log.info('Resolving IP address for target host $targetHost...');
      String? ipAddress;
      final ip4 = await _firstOrNull(
        _mdnsClient.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(targetHost),
          timeout: const Duration(seconds: 2),
        ),
      );

      if (ip4 != null) {
        ipAddress = ip4.address.address;
        _log.info('IPv4 resolved: $ipAddress');
      } else {
        _log.info('IPv4 lookup failed/timeout. Trying IPv6...');
        final ip6 = await _firstOrNull(
          _mdnsClient.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv6(targetHost),
            timeout: const Duration(seconds: 2),
          ),
        );
        ipAddress = ip6?.address.address;
        if (ipAddress != null) {
          _log.info('IPv6 resolved: $ipAddress');
        } else {
          _log.warning(
            'Could not resolve any IP address (IPv4/IPv6) for $targetHost.',
          );
        }
      }

      // 4. Create scanner device
      if (ipAddress != null) {
        final path = MdnsTxtParser.extractPath(txtMap);
        final defaultName = domainName.split('.').first;
        final name = MdnsTxtParser.extractName(txtMap, defaultName);
        final id = '${ipAddress}_$port';

        // EPSON scanners announce via _uscan._tcp (HTTP) but actually
        // serve HTTPS on port 443. Detect this to set isSecure correctly.
        final effectiveSecure = isSecure || port == 443;

        _log.info(
          'Scanner device created -> ID: $id, Name: $name, Path: $path, '
          'isSecure: $effectiveSecure (from service: $isSecure, port: $port)',
        );

        devices[id] = ScannerDevice(
          id: id,
          name: name,
          ip: ipAddress,
          port: port,
          path: path,
          isSecure: effectiveSecure,
        );
      }
    }
  }

  /// Helper to safely read the first element of a stream, returning null on error/empty.
  Future<T?> _firstOrNull<T>(Stream<T> stream) async {
    try {
      return await stream.first;
    } catch (_) {
      return null;
    }
  }
}
