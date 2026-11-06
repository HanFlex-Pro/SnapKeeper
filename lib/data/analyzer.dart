import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import '../core/image_features.dart';
import '../core/quality.dart';
import '../core/thresholds.dart';
import 'database.dart';
import 'photo_info.dart';

/// [paths]를 분석해 [db]에 저장한다. 진행 상황은 (끝난 수, 전체 수)로 알린다.
///
/// - 디코딩은 메인 Isolate에서만 된다(M0 검증). 해시·EXIF·특징 계산만 Isolate에서 한다.
/// - 묶음 단위로 저장하므로 중간에 멈춰도 다음 실행에서 남은 것만 분석한다.
/// - [isCancelled]가 true가 되면 진행 중인 파일까지만 처리하고 멈춘다.
Future<void> analyzePhotos(
  PhotoDatabase db,
  List<String> paths, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  int workers = 4,
  int batchSize = 50,
}) async {
  var next = 0, done = 0;
  final batch = <String, PhotoAnalysis>{};

  void flush() {
    if (batch.isEmpty) return;
    db.saveAnalyses(batch);
    batch.clear();
  }

  Future<void> worker() async {
    while (next < paths.length && !(isCancelled?.call() ?? false)) {
      final path = paths[next++];
      final result = await analyzePhoto(path);
      if (result != null) batch[path] = result;
      done++;
      if (batch.length >= batchSize) flush();
      onProgress?.call(done, paths.length);
    }
  }

  await Future.wait(List.generate(workers, (_) => worker()));
  flush();
}

/// 파일을 읽을 수 없으면(분석 중 삭제 등) null. 다음 스캔에서 정리된다.
Future<PhotoAnalysis?> analyzePhoto(String path) async {
  final Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } on FileSystemException {
    return null;
  }
  Decoded? decoded;
  String? error;
  try {
    decoded = await decodeForAnalysis(bytes);
  } catch (e) {
    error = '디코딩 실패: $e';
  }
  final rgba = decoded?.rgba, w = decoded?.width ?? 0, h = decoded?.height ?? 0;
  final (sha, features, exif, marker) = await Isolate.run(() async {
    final exif = await readExifFields(bytes);
    return (
      sha256.convert(bytes).toString(),
      rgba == null ? null : computeFeatures(rgba, w, h),
      exif,
      // 카메라로 찍은 사진은 캡처가 아니므로 찾지 않는다.
      exif.camera == null &&
          hasScreenshotMarker(
            Uint8List.sublistView(
              bytes,
              0,
              min(bytes.length, screenshotMarkerScanBytes),
            ),
          ),
    );
  });
  return PhotoAnalysis(
    sha256: sha,
    features: features,
    width: decoded?.sourceWidth,
    height: decoded?.sourceHeight,
    takenAt: exif.takenAt,
    camera: exif.camera,
    latitude: exif.latitude,
    longitude: exif.longitude,
    screenshotMarker: marker,
    error: error,
  );
}

class Decoded {
  const Decoded(
    this.sourceWidth,
    this.sourceHeight,
    this.width,
    this.height,
    this.rgba,
  );

  /// 원본 크기 (EXIF 회전 적용).
  final int sourceWidth, sourceHeight;

  /// 축소한 크기.
  final int width, height;
  final Uint8List rgba;
}

/// 긴 변이 [analysisMaxEdge]가 되도록 축소 디코딩한다. EXIF 회전이 적용된다.
Future<Decoded> decodeForAnalysis(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    final sw = descriptor.width, sh = descriptor.height;
    final scale = min(1.0, analysisMaxEdge / max(sw, sh));
    final codec = await descriptor.instantiateCodec(
      targetWidth: max(1, (sw * scale).round()),
      targetHeight: max(1, (sh * scale).round()),
    );
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = Decoded(
      sw,
      sh,
      image.width,
      image.height,
      data!.buffer.asUint8List(),
    );
    image.dispose();
    codec.dispose();
    return result;
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}
