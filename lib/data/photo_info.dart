import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';

class PhotoInfo {
  const PhotoInfo({this.width, this.height, this.takenAt, this.camera});

  /// EXIF 회전을 적용한 크기. 디코딩할 수 없으면 null.
  final int? width;
  final int? height;
  final DateTime? takenAt;
  final String? camera;
}

/// 해상도, 촬영일, 카메라를 읽는다. 읽을 수 없는 항목은 null로 둔다.
Future<PhotoInfo> readPhotoInfo(String path) async {
  final bytes = await File(path).readAsBytes();
  final (takenAt, camera) = await Isolate.run(() => readExifFields(bytes));
  int? width, height;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    width = descriptor.width;
    height = descriptor.height;
    descriptor.dispose();
    buffer.dispose();
  } catch (_) {
    // 디코딩할 수 없는 형식 (예: Windows의 HEIC)
  }
  return PhotoInfo(
    width: width,
    height: height,
    takenAt: takenAt,
    camera: camera,
  );
}

/// EXIF에서 촬영일과 카메라 이름을 꺼낸다.
/// `readExifFromFile`은 파싱 오류 시 파일을 닫지 않아 바이트로 읽는다.
Future<(DateTime?, String?)> readExifFields(Uint8List bytes) async {
  final Map<String, IfdTag> tags;
  try {
    tags = await readExifFromBytes(bytes, details: false);
  } catch (_) {
    return (null, null);
  }
  final date =
      tags['EXIF DateTimeOriginal']?.printable ??
      tags['Image DateTime']?.printable;
  final make = tags['Image Make']?.printable.trim() ?? '';
  final model = tags['Image Model']?.printable.trim() ?? '';
  final camera = model.startsWith(make) ? model : '$make $model'.trim();
  return (parseExifDate(date), camera.isEmpty ? null : camera);
}

/// `2023:05:01 14:30:15` 형식. 형식이 다르거나 값이 비었으면 null.
DateTime? parseExifDate(String? value) {
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
      .firstMatch(value?.trim() ?? '');
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (p[0] == 0) return null; // 0000:00:00 00:00:00
  return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
}
