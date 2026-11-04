import 'dart:math';
import 'dart:typed_data';

/// 축소 디코딩한 RGBA 픽셀에서 계산한 비교용 값.
class ImageFeatures {
  const ImageFeatures(
    this.phash,
    this.meanRgb,
    this.grayStd,
    this.saturation,
    this.sharpness,
  );

  /// 64비트 지각 해시.
  final int phash;

  /// 평균 색. 0xRRGGBB.
  final int meanRgb;

  /// 밝기 표준편차. 작을수록 평탄한 이미지.
  final double grayStd;

  /// 픽셀별 (최대 채널 - 최소 채널)의 평균. 흑백 이미지는 0.
  final double saturation;

  /// 8×8 타일별 라플라시안 분산의 최댓값. 가장 선명한 부분의 선명도.
  final double sharpness;
}

ImageFeatures computeFeatures(Uint8List rgba, int width, int height) {
  final n = width * height;
  if (n == 0 || rgba.length < n * 4) {
    throw ArgumentError('픽셀 수가 맞지 않음: $width×$height, ${rgba.length}바이트');
  }
  final gray = Float64List(n);
  var r = 0, g = 0, b = 0;
  var sum = 0.0, sq = 0.0, chroma = 0;
  for (var i = 0; i < n; i++) {
    final pr = rgba[i * 4], pg = rgba[i * 4 + 1], pb = rgba[i * 4 + 2];
    r += pr;
    g += pg;
    b += pb;
    chroma += max(pr, max(pg, pb)) - min(pr, min(pg, pb));
    final y = 0.299 * pr + 0.587 * pg + 0.114 * pb;
    gray[i] = y;
    sum += y;
    sq += y * y;
  }
  final mean = sum / n;
  final mr = r ~/ n, mg = g ~/ n, mb = b ~/ n;
  return ImageFeatures(
    _phash(gray, width, height),
    (mr << 16) | (mg << 8) | mb,
    sqrt(max(0, sq / n - mean * mean)),
    chroma / n,
    sharpness(gray, width, height),
  );
}

const _tiles = 8;

/// 타일별 라플라시안 분산의 최댓값. 배경이 흐려도 피사체 타일이 선명하면 값이 높다.
/// 분석용 축소 이미지(긴 변 `analysisMaxEdge`)에서 계산한 값끼리만 비교한다.
double sharpness(Float64List gray, int w, int h) {
  if (w < 3 || h < 3) return 0;
  var best = 0.0;
  for (var ty = 0; ty < _tiles; ty++) {
    final y0 = max(1, ty * h ~/ _tiles),
        y1 = min(h - 1, (ty + 1) * h ~/ _tiles);
    for (var tx = 0; tx < _tiles; tx++) {
      final x0 = max(1, tx * w ~/ _tiles),
          x1 = min(w - 1, (tx + 1) * w ~/ _tiles);
      var sum = 0.0, sq = 0.0, count = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = y * w + x;
          final l =
              gray[i - 1] +
              gray[i + 1] +
              gray[i - w] +
              gray[i + w] -
              4 * gray[i];
          sum += l;
          sq += l * l;
          count++;
        }
      }
      if (count == 0) continue;
      final mean = sum / count;
      best = max(best, sq / count - mean * mean);
    }
  }
  return best;
}

const _size = 32;

/// 32×32 흑백으로 줄인 뒤 DCT 저주파 8×8 계수의 중앙값 비교로 64비트를 만든다.
int _phash(Float64List gray, int w, int h) {
  final s = Float64List(_size * _size);
  final c = Int32List(_size * _size);
  for (var y = 0; y < h; y++) {
    final row = (y * _size ~/ h) * _size;
    for (var x = 0; x < w; x++) {
      final i = row + x * _size ~/ w;
      s[i] += gray[y * w + x];
      c[i]++;
    }
  }
  for (var i = 0; i < s.length; i++) {
    if (c[i] > 0) s[i] /= c[i];
  }
  final cosines = List.generate(
    8,
    (u) => Float64List.fromList([
      for (var x = 0; x < _size; x++) cos((2 * x + 1) * u * pi / (2 * _size)),
    ]),
  );
  final dct = Float64List(64);
  for (var u = 0; u < 8; u++) {
    for (var v = 0; v < 8; v++) {
      var sum = 0.0;
      for (var y = 0; y < _size; y++) {
        final cu = cosines[u][y];
        for (var x = 0; x < _size; x++) {
          sum += s[y * _size + x] * cu * cosines[v][x];
        }
      }
      dct[u * 8 + v] = sum;
    }
  }
  // 직류 성분(0번)은 전체 밝기라 중앙값 계산에서 뺀다.
  final ac = Float64List.fromList(dct.sublist(1))..sort();
  final median = ac[ac.length ~/ 2];
  var hash = 0;
  for (var i = 0; i < 64; i++) {
    if (dct[i] > median) hash |= 1 << i;
  }
  return hash;
}

int hammingDistance(int a, int b) {
  var x = a ^ b;
  var count = 0;
  while (x != 0) {
    x &= x - 1;
    count++;
  }
  return count;
}

/// 채널별 차이 중 가장 큰 값.
int colorDistance(int a, int b) => [
  16,
  8,
  0,
].map((s) => ((a >> s & 0xff) - (b >> s & 0xff)).abs()).reduce(max);
