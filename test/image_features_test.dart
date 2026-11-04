import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/image_features.dart';
import 'package:snapkeeper/core/thresholds.dart';

/// 그라데이션 위에 사각형이 흩어진 합성 사진.
Uint8List scene(int w, int h, {int seed = 1}) {
  final rnd = Random(seed);
  final rects = [
    for (var i = 0; i < 12; i++)
      (
        rnd.nextInt(w),
        rnd.nextInt(h),
        20 + rnd.nextInt(w ~/ 3),
        20 + rnd.nextInt(h ~/ 3),
        rnd.nextInt(256),
        rnd.nextInt(256),
        rnd.nextInt(256),
      ),
  ];
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = x * 255 ~/ w, g = y * 255 ~/ h, b = 128;
      for (final (rx, ry, rw, rh, cr, cg, cb) in rects) {
        if (x >= rx && x < rx + rw && y >= ry && y < ry + rh) {
          r = cr;
          g = cg;
          b = cb;
        }
      }
      final i = (y * w + x) * 4;
      px[i] = r;
      px[i + 1] = g;
      px[i + 2] = b;
      px[i + 3] = 255;
    }
  }
  return px;
}

Uint8List map(Uint8List px, int Function(int value, int channel, int i) f) {
  final out = Uint8List.fromList(px);
  for (var i = 0; i < out.length; i++) {
    if (i % 4 != 3) out[i] = f(out[i], i % 4, i).clamp(0, 255);
  }
  return out;
}

void main() {
  const w = 320, h = 240;
  final base = scene(w, h);
  final f = computeFeatures(base, w, h);

  int distanceTo(Uint8List other) =>
      hammingDistance(f.phash, computeFeatures(other, w, h).phash);

  test('같은 픽셀은 같은 해시', () {
    expect(computeFeatures(Uint8List.fromList(base), w, h).phash, f.phash);
  });

  test('약한 노이즈와 밝기 변화는 거의 동일 기준 안', () {
    final rnd = Random(7);
    final noisy = map(base, (v, _, _) => v + rnd.nextInt(7) - 3);
    final brighter = map(base, (v, _, _) => v + 8);

    expect(distanceTo(noisy), lessThanOrEqualTo(nearDuplicateMaxHamming));
    expect(distanceTo(brighter), lessThanOrEqualTo(nearDuplicateMaxHamming));
  });

  test('다른 사진은 해시가 크게 다름', () {
    expect(distanceTo(scene(w, h, seed: 2)), greaterThan(10));
  });

  test('평균 색과 밝기 분산', () {
    final red = map(base, (_, c, _) => c == 0 ? 200 : 0);
    final rf = computeFeatures(red, w, h);

    expect(rf.meanRgb, 0xC80000);
    expect(rf.grayStd, closeTo(0, 0.001));
    expect(f.grayStd, greaterThan(flatImageMaxGrayStd));
  });

  test('흑백본은 채도로 구분', () {
    final gray = map(base, (_, _, i) {
      final p = i - i % 4;
      return (0.299 * base[p] + 0.587 * base[p + 1] + 0.114 * base[p + 2])
          .round();
    });
    final gf = computeFeatures(gray, w, h);

    expect(gf.saturation, closeTo(0, 1));
    expect(
      (f.saturation - gf.saturation).abs(),
      greaterThan(nearDuplicateMaxSaturationDiff),
    );
  });

  test('해밍 거리와 색 거리', () {
    expect(hammingDistance(0, 0), 0);
    expect(hammingDistance(0, -1), 64);
    expect(hammingDistance(0x0F, 0xF0), 8);
    expect(colorDistance(0x102030, 0x152530), 5);
  });

  test('픽셀 수가 맞지 않으면 오류', () {
    expect(() => computeFeatures(Uint8List(10), 4, 4), throwsArgumentError);
  });

  // 테스트 이미지는 tool/make_test_fixtures.swift로 만든다.
  testWidgets('화질만 다르게 저장한 같은 JPEG는 거의 동일 기준 안', (tester) async {
    Future<ImageFeatures> featuresOf(String name) async {
      final bytes = File('test/fixtures/$name').readAsBytesSync();
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return computeFeatures(
        data!.buffer.asUint8List(),
        image.width,
        image.height,
      );
    }

    final (high, low) = (await tester.runAsync(
      () async => (
        await featuresOf('scene_q90.jpg'),
        await featuresOf('scene_q40.jpg'),
      ),
    ))!;

    expect(
      hammingDistance(high.phash, low.phash),
      lessThanOrEqualTo(nearDuplicateMaxHamming),
    );
    expect(
      colorDistance(high.meanRgb, low.meanRgb),
      lessThanOrEqualTo(nearDuplicateMaxColorDiff),
    );
    expect(
      (high.saturation - low.saturation).abs(),
      lessThanOrEqualTo(nearDuplicateMaxSaturationDiff),
    );
  });

  group('선명도', () {
    /// 3×3 상자 흐림을 [times]번 적용한다. [region]이 있으면 그 밖만 흐리게 한다.
    Uint8List blur(
      Uint8List px,
      int times, {
      bool Function(int x, int y)? keep,
    }) {
      var cur = Uint8List.fromList(px);
      for (var t = 0; t < times; t++) {
        final next = Uint8List.fromList(cur);
        for (var y = 1; y < h - 1; y++) {
          for (var x = 1; x < w - 1; x++) {
            if (keep != null && keep(x, y)) continue;
            for (var c = 0; c < 3; c++) {
              var sum = 0;
              for (var dy = -1; dy <= 1; dy++) {
                for (var dx = -1; dx <= 1; dx++) {
                  sum += cur[((y + dy) * w + x + dx) * 4 + c];
                }
              }
              next[(y * w + x) * 4 + c] = sum ~/ 9;
            }
          }
        }
        cur = next;
      }
      return cur;
    }

    test('흐리게 할수록 선명도가 떨어진다', () {
      final s0 = f.sharpness;
      final s1 = computeFeatures(blur(base, 2), w, h).sharpness;
      final s2 = computeFeatures(blur(base, 6), w, h).sharpness;

      expect(s1, lessThan(s0 * 0.5));
      expect(s2, lessThan(s1));
    });

    test('배경만 흐려도 선명한 부분이 있으면 선명도가 유지된다', () {
      // 가운데 1/8 영역만 원본 그대로 두고 나머지를 흐리게 한다.
      final subject = blur(
        base,
        6,
        keep: (x, y) =>
            x >= w * 7 ~/ 16 &&
            x < w * 9 ~/ 16 &&
            y >= h * 7 ~/ 16 &&
            y < h * 9 ~/ 16,
      );
      final allBlurred = computeFeatures(blur(base, 6), w, h).sharpness;

      expect(
        computeFeatures(subject, w, h).sharpness,
        greaterThan(allBlurred * 3),
      );
    });

    test('평탄한 이미지는 선명도 0', () {
      final flat = map(base, (_, _, _) => 128);

      expect(computeFeatures(flat, w, h).sharpness, closeTo(0, 0.001));
    });
  });
}
