import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';

/// Intent of the scan job.
enum ScanIntent {
  preview,
  finalScan,
}

/// Source of the document to be scanned.
enum DocumentSource {
  platen,
  adf,
}

/// Target mode: create a new PDF or append to an existing one.
enum TargetMode {
  newPdf,
  append,
}

/// Represents a discovered eSCL scanner device.
@JsonSerializable()
class ScannerDevice {
  final String id;
  final String name;
  final String ip;
  final int port;
  final String path;
  final bool isSecure;

  const ScannerDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.path,
    required this.isSecure,
  });

  factory ScannerDevice.fromJson(Map<String, dynamic> json) =>
      _$ScannerDeviceFromJson(json);

  Map<String, dynamic> toJson() => _$ScannerDeviceToJson(this);
}

/// Relative coordinate region for cropping an image.
@JsonSerializable()
class CropRegion {
  final double xRatio;
  final double yRatio;
  final double widthRatio;
  final double heightRatio;

  const CropRegion({
    required this.xRatio,
    required this.yRatio,
    required this.widthRatio,
    required this.heightRatio,
  });

  factory CropRegion.fromJson(Map<String, dynamic> json) =>
      _$CropRegionFromJson(json);

  Map<String, dynamic> toJson() => _$CropRegionToJson(this);
}

/// Configuration for a scan job.
@JsonSerializable()
class ScanJobConfig {
  final String scannerId;
  final ScanIntent intent;
  final DocumentSource source;
  final int dpi;
  final String colorMode;
  final CropRegion? crop;
  final TargetMode targetMode;
  final String? targetPdfId;

  /// Output document format, e.g. "image/jpeg" or "application/pdf".
  /// Used as the value of `<scan:DocumentFormatExt>` in the eSCL XML.
  /// Defaults to "image/jpeg" for backward compatibility.
  @JsonKey(defaultValue: 'image/jpeg')
  final String documentFormat;

  const ScanJobConfig({
    required this.scannerId,
    required this.intent,
    required this.source,
    required this.dpi,
    required this.colorMode,
    this.crop,
    required this.targetMode,
    this.targetPdfId,
    this.documentFormat = 'image/jpeg',
  });

  factory ScanJobConfig.fromJson(Map<String, dynamic> json) =>
      _$ScanJobConfigFromJson(json);

  Map<String, dynamic> toJson() => _$ScanJobConfigToJson(this);
}

/// Metadata for a scanned file persisted on the backend.
///
/// Used by the scan history list (`GET /api/v1/scans`) and the append-target
/// dropdown. [modifiedAt] changes when a file is appended to, which keeps the
/// most recently used PDFs at the top of the list.
@JsonSerializable()
class ScannedFile {
  final String id;

  /// Human-readable display name (e.g. "Scan 2026-08-15 20:30:00.pdf").
  final String name;
  final String mimeType;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime modifiedAt;

  const ScannedFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
    required this.modifiedAt,
  });

  factory ScannedFile.fromJson(Map<String, dynamic> json) =>
      _$ScannedFileFromJson(json);

  Map<String, dynamic> toJson() => _$ScannedFileToJson(this);
}
