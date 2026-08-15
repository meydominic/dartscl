import 'dart:typed_data';
import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:image/image.dart' as img;

/// Generates a small gray JPEG that serves as a placeholder scan result
/// when no real scanner is available.
///
/// The image is created programmatically (instead of hardcoded bytes) so
/// it is guaranteed to be decodable by the `image` package used in
/// [PdfProcessingPipeline] — a hardcoded byte blob that the decoder
/// rejects breaks every mock-based crop/PDF code path.
final Uint8List dummyJpeg = img.encodeJpg(
  img.fill(
    img.Image(width: 16, height: 16),
    color: img.ColorRgb8(200, 200, 200),
  ),
  quality: 90,
);

/// Mock service that returns hardcoded scanner lists and dummy images.
///
/// Used when mDNS discovery finds no real devices on the network or when
/// running in development/testing mode.
class MockScannerService {
  /// Returns a list of mock [ScannerDevice] instances for testing.
  List<ScannerDevice> get scanners => [
        const ScannerDevice(
          id: 'mock-1',
          name: 'Epson WorkForce WF-2521',
          ip: '192.168.1.100',
          port: 765,
          path: '/eSCL',
          isSecure: false,
        ),
        const ScannerDevice(
          id: 'mock-2',
          name: 'Brother MFC-L2710DW',
          ip: '192.168.1.101',
          port: 765,
          path: '/eSCL',
          isSecure: false,
        ),
      ];

  /// Returns hardcoded dummy JPEG image bytes.
  Uint8List get dummyImage => dummyJpeg;

  /// Returns hardcoded scanner capabilities for mock devices.
  Map<String, dynamic> get dummyCapabilities => {
        'dpi': [75, 150, 300, 600],
        'colorModes': ['RGB24', 'Grayscale8', 'B&W1'],
        'sources': ['platen', 'adf'],
        'maxWidth': 2159,
        'maxHeight': 2983,
      };
}

/// Singleton instance for easy access in routes.
final MockScannerService _instance = MockScannerService();

/// Global accessor for the shared [MockScannerService] singleton.
MockScannerService get mockScannerService => _instance;
