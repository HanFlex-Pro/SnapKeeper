import 'dart:convert';
import 'dart:typed_data';

import 'duplicates.dart';
import 'thresholds.dart';

enum QualityIssue { screenshot, lowResolution, blurry }

class QualityCandidate {
  const QualityCandidate(this.photo, this.issue, this.reason);

  final PhotoRecord photo;
  final QualityIssue issue;

  /// 사용자에게 보여 줄 탐지 이유.
  final String reason;
}

/// 캡처·저화질·초점 불량 후보를 분류별로 찾는다. 한 사진이 여러 분류에 나올 수 있다.
/// 보관한 사진, 아직 분석하지 않았거나 분석에 실패한 사진은 제외한다.
Map<QualityIssue, List<QualityCandidate>> findQualityIssues(
  List<PhotoRecord> photos, {
  Set<String> keptSha256 = const {},
}) {
  final result = {
    for (final issue in QualityIssue.values) issue: <QualityCandidate>[],
  };
  for (final p in photos) {
    if (p.sha256 == null || p.error != null || keptSha256.contains(p.sha256)) {
      continue;
    }
    final screenshot = screenshotReason(p);
    if (screenshot != null) {
      result[QualityIssue.screenshot]!.add(
        QualityCandidate(p, QualityIssue.screenshot, screenshot),
      );
    }
    if (p.camera == null && p.pixels > 0 && p.pixels < lowResolutionMaxPixels) {
      result[QualityIssue.lowResolution]!.add(
        QualityCandidate(
          p,
          QualityIssue.lowResolution,
          '${p.width}×${p.height} (${_mp(p.pixels)}MP), '
          '기준 ${_mp(lowResolutionMaxPixels)}MP 미만',
        ),
      );
    }
    final grayStd = p.grayStd, sharpness = p.sharpness;
    String? blurReason;
    if (grayStd != null && grayStd < nearlyBlankMaxGrayStd) {
      blurReason = '거의 단색 (밝기 편차 ${grayStd.toStringAsFixed(0)})';
    } else if (sharpness != null && sharpness < blurryMaxSharpness) {
      blurReason =
          '선명도 ${sharpness.toStringAsFixed(0)}, '
          '기준 ${blurryMaxSharpness.toStringAsFixed(0)} 미만';
    }
    if (blurReason != null) {
      result[QualityIssue.blurry]!.add(
        QualityCandidate(p, QualityIssue.blurry, blurReason),
      );
    }
  }
  result[QualityIssue.screenshot]!.sort(
    (a, b) => b.photo.modified.compareTo(a.photo.modified),
  );
  result[QualityIssue.lowResolution]!.sort(
    (a, b) => a.photo.pixels.compareTo(b.photo.pixels),
  );
  result[QualityIssue.blurry]!.sort(
    (a, b) => (a.photo.sharpness ?? 0).compareTo(b.photo.sharpness ?? 0),
  );
  return result;
}

const _screenshotNames = [
  'screenshot',
  'screen shot',
  'screen_shot',
  '스크린샷',
  '화면 캡처',
  '화면캡처',
  'capture',
];
const _screenshotFolders = {'screenshots', 'screenshot', '스크린샷'};

/// 흔한 화면 해상도 (가로 기준, 세로 방향도 함께 확인한다).
const _screenSizes = {
  // iPhone
  (750, 1334), (828, 1792), (1125, 2436), (1170, 2532), (1179, 2556),
  (1242, 2688), (1284, 2778), (1290, 2796), (1206, 2622), (1320, 2868),
  // Android
  (720, 1600), (1080, 1920), (1080, 2220), (1080, 2340), (1080, 2400),
  (1440, 2960), (1440, 3088), (1440, 3200),
  // 데스크톱·노트북
  (1280, 800), (1366, 768), (1440, 900), (1680, 1050), (1920, 1080),
  (1920, 1200), (2560, 1440), (2560, 1600), (2880, 1800), (2940, 1912),
  (3024, 1964), (3456, 2234), (3840, 2160),
};

/// 캡처로 볼 근거. 카메라 EXIF가 있으면 카메라로 찍은 사진으로 보고 null.
String? screenshotReason(PhotoRecord p) {
  if (p.screenshotMarker == true) return '캡처 표시가 있음 (iPhone·macOS)';
  if (p.camera != null) return null;
  final parts = p.path.split(RegExp(r'[\\/]'));
  final name = parts.last.toLowerCase();
  if (_screenshotNames.any(name.contains) || name.startsWith('scr_')) {
    return '카메라 정보 없음 + 파일명이 캡처 형식';
  }
  if (parts.length > 1 &&
      _screenshotFolders.contains(parts[parts.length - 2].toLowerCase())) {
    return '카메라 정보 없음 + 캡처 폴더';
  }
  final w = p.width, h = p.height;
  if (name.endsWith('.png') &&
      w != null &&
      h != null &&
      (_screenSizes.contains((w, h)) || _screenSizes.contains((h, w)))) {
    return '카메라 정보 없음 + PNG, 화면 크기 $w×$h';
  }
  return null;
}

String _mp(int pixels) => (pixels / 1000000).toStringAsFixed(2);

final _markers = [
  ascii.encode('ASCII\u0000\u0000\u0000Screenshot'), // EXIF 사용자 메모
  ascii.encode('<exif:UserComment>Screenshot<'), // XMP
];

/// iPhone·macOS 캡처는 EXIF 사용자 메모와 XMP에 "Screenshot"을 남긴다.
/// exif 패키지는 PNG 안의 EXIF를 읽지 못해 파일 앞부분 바이트에서 직접 찾는다.
bool hasScreenshotMarker(Uint8List head) {
  for (final m in _markers) {
    outer:
    for (var i = 0; i + m.length <= head.length; i++) {
      if (head[i] != m[0]) continue;
      for (var j = 1; j < m.length; j++) {
        if (head[i + j] != m[j]) continue outer;
      }
      return true;
    }
  }
  return false;
}

/// 표시를 찾을 파일 앞부분 크기.
const screenshotMarkerScanBytes = 256 * 1024;
