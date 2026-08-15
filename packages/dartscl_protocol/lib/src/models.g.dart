// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ScannerDevice _$ScannerDeviceFromJson(Map<String, dynamic> json) =>
    ScannerDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      ip: json['ip'] as String,
      port: (json['port'] as num).toInt(),
      path: json['path'] as String,
      isSecure: json['isSecure'] as bool,
    );

Map<String, dynamic> _$ScannerDeviceToJson(ScannerDevice instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'ip': instance.ip,
      'port': instance.port,
      'path': instance.path,
      'isSecure': instance.isSecure,
    };

CropRegion _$CropRegionFromJson(Map<String, dynamic> json) => CropRegion(
      xRatio: (json['xRatio'] as num).toDouble(),
      yRatio: (json['yRatio'] as num).toDouble(),
      widthRatio: (json['widthRatio'] as num).toDouble(),
      heightRatio: (json['heightRatio'] as num).toDouble(),
    );

Map<String, dynamic> _$CropRegionToJson(CropRegion instance) =>
    <String, dynamic>{
      'xRatio': instance.xRatio,
      'yRatio': instance.yRatio,
      'widthRatio': instance.widthRatio,
      'heightRatio': instance.heightRatio,
    };

ScanJobConfig _$ScanJobConfigFromJson(Map<String, dynamic> json) =>
    ScanJobConfig(
      scannerId: json['scannerId'] as String,
      intent: $enumDecode(_$ScanIntentEnumMap, json['intent']),
      source: $enumDecode(_$DocumentSourceEnumMap, json['source']),
      dpi: (json['dpi'] as num).toInt(),
      colorMode: json['colorMode'] as String,
      crop: json['crop'] == null
          ? null
          : CropRegion.fromJson(json['crop'] as Map<String, dynamic>),
      targetMode: $enumDecode(_$TargetModeEnumMap, json['targetMode']),
      targetPdfId: json['targetPdfId'] as String?,
      documentFormat: json['documentFormat'] as String? ?? 'image/jpeg',
    );

Map<String, dynamic> _$ScanJobConfigToJson(ScanJobConfig instance) =>
    <String, dynamic>{
      'scannerId': instance.scannerId,
      'intent': _$ScanIntentEnumMap[instance.intent]!,
      'source': _$DocumentSourceEnumMap[instance.source]!,
      'dpi': instance.dpi,
      'colorMode': instance.colorMode,
      'crop': instance.crop,
      'targetMode': _$TargetModeEnumMap[instance.targetMode]!,
      'targetPdfId': instance.targetPdfId,
      'documentFormat': instance.documentFormat,
    };

const _$ScanIntentEnumMap = {
  ScanIntent.preview: 'preview',
  ScanIntent.finalScan: 'finalScan',
};

const _$DocumentSourceEnumMap = {
  DocumentSource.platen: 'platen',
  DocumentSource.adf: 'adf',
};

const _$TargetModeEnumMap = {
  TargetMode.newPdf: 'newPdf',
  TargetMode.append: 'append',
};

ScannedFile _$ScannedFileFromJson(Map<String, dynamic> json) => ScannedFile(
      id: json['id'] as String,
      name: json['name'] as String,
      mimeType: json['mimeType'] as String,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      modifiedAt: DateTime.parse(json['modifiedAt'] as String),
    );

Map<String, dynamic> _$ScannedFileToJson(ScannedFile instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'mimeType': instance.mimeType,
      'sizeBytes': instance.sizeBytes,
      'createdAt': instance.createdAt.toIso8601String(),
      'modifiedAt': instance.modifiedAt.toIso8601String(),
    };
