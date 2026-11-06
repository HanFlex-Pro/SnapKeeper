// 초점 불량 지표 실험. 앱 코드는 바꾸지 않고, 새 지표가 흐린 사진과 하늘 같은
// 세부가 적은 사진을 가르는지 확인한다. 사진은 읽기만 한다.
//
//   flutter test tool/experiment_blur.dart \
//     --dart-define=LABELS=<라벨 tsv: 키\t정답\t경로> --dart-define=PHOTOS=<폴더>
//
// 새 지표: 8×8 타일 중 윤곽이 있는 타일(기울기 에너지가 기준 이상)만 보고,
// 그 타일의 "라플라시안 분산 ÷ 기울기 에너지" 최댓값을 쓴다. 번진 윤곽은 이 비율이 낮다.
// 윤곽이 있는 타일이 없으면(하늘 등) 판단하지 않는다.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/analyzer.dart';
import 'package:snapkeeper/data/photo_scanner.dart';

const _labels = String.fromEnvironment('LABELS');
const _photos = String.fromEnvironment('PHOTOS');

/// 지정하면 사진별 새 지표(g50 윤곽 타일 수, 비율)를 CSV로 내보낸다. 저장소 밖 경로를 쓴다.
const _csv = String.fromEnvironment('CSV');

/// 지정하면 인공 흐림 실험을 한다. 정상 사진 경로 목록(한 줄에 하나) 파일.
const _synth = String.fromEnvironment('SYNTH');

/// (윤곽 타일 수, 최대 비율, 최대 라플라시안 분산) — 기울기 에너지 기준값별.
typedef Scores = Map<int, (int, double?)>;

const _edgeThresholds = [50, 100, 200, 400];

Scores score(Uint8List rgba, int w, int h) {
  final g = Float64List(w * h);
  for (var i = 0; i < g.length; i++) {
    g[i] =
        0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
  }
  const tiles = 8;
  final result = <int, (int, double?)>{};
  final perTile = <(double, double)>[]; // (기울기 에너지, 라플라시안 분산)
  for (var ty = 0; ty < tiles; ty++) {
    final y0 = max(1, ty * h ~/ tiles), y1 = min(h - 1, (ty + 1) * h ~/ tiles);
    for (var tx = 0; tx < tiles; tx++) {
      final x0 = max(1, tx * w ~/ tiles),
          x1 = min(w - 1, (tx + 1) * w ~/ tiles);
      var grad = 0.0, sum = 0.0, sq = 0.0, n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = y * w + x;
          final gx = (g[i + 1] - g[i - 1]) / 2, gy = (g[i + w] - g[i - w]) / 2;
          grad += gx * gx + gy * gy;
          final l = g[i - 1] + g[i + 1] + g[i - w] + g[i + w] - 4 * g[i];
          sum += l;
          sq += l * l;
          n++;
        }
      }
      if (n == 0) continue;
      final mean = sum / n;
      perTile.add((grad / n, sq / n - mean * mean));
    }
  }
  for (final t in _edgeThresholds) {
    final edged = perTile.where((p) => p.$1 >= t).toList();
    result[t] = (
      edged.length,
      edged.isEmpty ? null : edged.map((p) => p.$2 / p.$1).reduce(max),
    );
  }
  return result;
}

Future<Scores?> scoreFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final d = await decodeForAnalysis(bytes);
  final rgba = d.rgba, w = d.width, h = d.height;
  return Isolate.run(() => score(rgba, w, h));
}

String fmt(double? v) => v == null ? '  -  ' : v.toStringAsFixed(2).padLeft(5);

void main() {
  if (_synth.isNotEmpty) return synthMain();
  testWidgets('초점 불량 지표 실험', timeout: Timeout.none, (tester) async {
    await tester.runAsync(() async {
      final rows = [
        if (_labels.isNotEmpty)
          for (final l in File(_labels).readAsLinesSync())
            if (l.trim().isNotEmpty) l.split('\t'),
      ];
      print('\n# 라벨 사진 (${rows.length}장): 키 정답 | 기울기 기준별 [윤곽 타일 수, 최대 비율]');
      final byLabel = <String, List<Scores>>{};
      for (final r in rows) {
        final s = (await scoreFile(r[2]))!;
        byLabel.putIfAbsent(r[1], () => []).add(s);
        print(
          '${r[0].padRight(4)} ${r[1].padRight(5)} | ${[for (final t in _edgeThresholds) 'g$t:${s[t]!.$1.toString().padLeft(2)},${fmt(s[t]!.$2)}'].join('  ')}',
        );
      }

      print('\n# 기울기 기준별 정답 그룹의 비율 범위 (윤곽 없음은 제외)');
      for (final t in _edgeThresholds) {
        final parts = <String>[];
        for (final lab in ['blur', 'maybe', 'sharp']) {
          final v = [
            for (final s in byLabel[lab] ?? <Scores>[])
              if (s[t]!.$2 != null) s[t]!.$2!,
          ]..sort();
          final none = (byLabel[lab] ?? [])
              .where((s) => s[t]!.$2 == null)
              .length;
          parts.add(
            '$lab ${v.isEmpty ? '-' : '${v.first.toStringAsFixed(2)}~${v.last.toStringAsFixed(2)}'} (윤곽 없음 $none)',
          );
        }
        print('g$t: ${parts.join(' | ')}');
      }

      if (_photos.isEmpty) return;
      print('\n# 전체 사진 분포');
      final all = <Scores>[];
      final low = <(String, double)>[];
      final csvLines = <String>['path,edge_tiles,ratio'];
      final listed = scanPhotosSync(_photos).photos;
      var next = 0;
      Future<void> worker() async {
        while (next < listed.length) {
          final path = listed[next++].path;
          final Scores? s;
          try {
            s = await scoreFile(path);
          } catch (_) {
            continue; // 디코딩할 수 없는 파일은 건너뛴다.
          }
          if (s == null) continue;
          all.add(s);
          csvLines.add(
            '"$path",${s[50]!.$1},${s[50]!.$2?.toStringAsFixed(3) ?? ''}',
          );
          final r = s[50]!.$2;
          if (r != null && r < 2.0) low.add((path, r));
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
      for (final t in _edgeThresholds) {
        final v = [
          for (final s in all)
            if (s[t]!.$2 != null) s[t]!.$2!,
        ]..sort();
        double q(double p) => v[((v.length - 1) * p).round()];
        final none = all.length - v.length;
        print(
          'g$t: 윤곽 없음 $none장 | 비율 1%=${q(.01).toStringAsFixed(2)} 5%=${q(.05).toStringAsFixed(2)} '
          '10%=${q(.1).toStringAsFixed(2)} 50%=${q(.5).toStringAsFixed(2)} | '
          '${[
            for (final c in [0.5, 1.0, 1.5, 2.0]) '<$c: ${v.where((x) => x < c).length}',
          ].join(' ')}',
        );
      }
      if (_csv.isNotEmpty) {
        File(_csv).writeAsStringSync('${csvLines.join('\n')}\n');
        print('CSV ${csvLines.length - 1}행 → $_csv');
      }
      low.sort((a, b) => a.$2.compareTo(b.$2));
      print('# g50 비율 2.0 미만 (${low.length}장)');
      for (final (p, r) in low) {
        print('LOW\t${r.toStringAsFixed(2)}\t$p');
      }
    });
  });
}

/// 가로·세로로 나눠 적용하는 가우시안 흐림. 메모리 안에서만 쓴다.
Uint8List gaussian(Uint8List src, int w, int h, double sigma) {
  final r = (sigma * 3).ceil();
  final k = [for (var i = -r; i <= r; i++) exp(-(i * i) / (2 * sigma * sigma))];
  final ks = k.reduce((a, b) => a + b);
  Uint8List pass(Uint8List a, bool horizontal) {
    final out = Uint8List.fromList(a);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        for (var c = 0; c < 3; c++) {
          var acc = 0.0;
          for (var i = -r; i <= r; i++) {
            final xx = horizontal ? (x + i).clamp(0, w - 1) : x;
            final yy = horizontal ? y : (y + i).clamp(0, h - 1);
            acc += a[(yy * w + xx) * 4 + c] * k[i + r];
          }
          out[(y * w + x) * 4 + c] = (acc / ks).round();
        }
      }
    }
    return out;
  }

  return pass(pass(src, true), false);
}

/// 가로 방향 움직임 흐림 (길이 [len]px 평균).
Uint8List motion(Uint8List src, int w, int h, int len) {
  final out = Uint8List.fromList(src);
  final half = len ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 3; c++) {
        var acc = 0;
        for (var i = -half; i < len - half; i++) {
          acc += src[(y * w + (x + i).clamp(0, w - 1)) * 4 + c];
        }
        out[(y * w + x) * 4 + c] = acc ~/ len;
      }
    }
  }
  return out;
}

void synthMain() {
  testWidgets('인공 흐림 재현율', timeout: Timeout.none, (tester) async {
    await tester.runAsync(() async {
      final paths = [
        for (final l in File(_synth).readAsLinesSync())
          if (l.trim().isNotEmpty) l.trim(),
      ];
      final levels = <String, Uint8List Function(Uint8List, int, int)>{
        '원본': (a, w, h) => a,
        'σ1': (a, w, h) => gaussian(a, w, h, 1),
        'σ2': (a, w, h) => gaussian(a, w, h, 2),
        'σ3': (a, w, h) => gaussian(a, w, h, 3),
        'σ5': (a, w, h) => gaussian(a, w, h, 5),
        '움직임5': (a, w, h) => motion(a, w, h, 5),
        '움직임10': (a, w, h) => motion(a, w, h, 10),
        '움직임20': (a, w, h) => motion(a, w, h, 20),
      };
      final ratios = {for (final k in levels.keys) k: <double?>[]};
      for (final p in paths) {
        final d = await decodeForAnalysis(await File(p).readAsBytes());
        final rgba = d.rgba, w = d.width, h = d.height;
        for (final e in levels.entries) {
          final f = e.value;
          final s = await Isolate.run(() => score(f(rgba, w, h), w, h));
          ratios[e.key]!.add(s[50]!.$2);
        }
      }
      print('\n# 인공 흐림 (${paths.length}장): 단계별 탐지율 (g50, 비율 기준 미만) / 윤곽 없음');
      for (final e in ratios.entries) {
        final v = e.value;
        String rate(double t) =>
            '${(100 * v.where((x) => x != null && x < t).length / v.length).round()}%';
        final none = v.where((x) => x == null).length;
        final known = [for (final x in v) ?x]..sort();
        final median = known.isEmpty
            ? '-'
            : known[known.length ~/ 2].toStringAsFixed(2);
        print(
          '${e.key.padRight(5)} <1.0 ${rate(1.0)} · <1.5 ${rate(1.5)} · <2.0 ${rate(2.0)} · '
          '윤곽 없음 $none장 · 중앙 비율 $median',
        );
      }
    });
  });
}
