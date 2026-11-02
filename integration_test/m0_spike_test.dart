// M0 기술 검증용 임시 코드. 결과를 문서에 기록한 뒤 삭제한다.
// 합성 이미지와 임시 폴더만 사용한다.
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

const _n = int.fromEnvironment('N', defaultValue: 200);
const _workers = int.fromEnvironment('WORKERS', defaultValue: 4);
const _trash = MethodChannel('snapkeeper/trash');
const _fixtures = 'integration_test/fixtures';

// ignore: avoid_print
void report(String line) => print('RESULT $line');

Future<Uint8List> asset(String name) async =>
    (await rootBundle.load('$_fixtures/$name')).buffer.asUint8List();

class Decoded {
  Decoded(this.srcW, this.srcH, this.w, this.h, this.rgba);
  final int srcW, srcH, w, h;
  final Uint8List rgba;
}

/// 긴 변이 [maxEdge]가 되도록 축소 디코딩한다.
Future<Decoded> decode(Uint8List bytes, {int maxEdge = 1024}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final sw = descriptor.width, sh = descriptor.height;
  final scale = min(1.0, maxEdge / max(sw, sh));
  final codec = await descriptor.instantiateCodec(
    targetWidth: (sw * scale).round(),
    targetHeight: (sh * scale).round(),
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = Decoded(
    sw,
    sh,
    image.width,
    image.height,
    data!.buffer.asUint8List(),
  );
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return out;
}

Float64List gray(Uint8List rgba) {
  final g = Float64List(rgba.length ~/ 4);
  for (var i = 0; i < g.length; i++) {
    g[i] =
        0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
  }
  return g;
}

int phash(Float64List g, int w, int h) {
  const n = 32;
  final s = Float64List(n * n);
  final c = Int32List(n * n);
  for (var y = 0; y < h; y++) {
    final sy = y * n ~/ h;
    for (var x = 0; x < w; x++) {
      final i = sy * n + x * n ~/ w;
      s[i] += g[y * w + x];
      c[i]++;
    }
  }
  for (var i = 0; i < s.length; i++) {
    if (c[i] > 0) s[i] /= c[i];
  }
  final dct = <double>[];
  for (var u = 0; u < 8; u++) {
    for (var v = 0; v < 8; v++) {
      var sum = 0.0;
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          sum +=
              s[y * n + x] *
              cos((2 * y + 1) * u * pi / (2 * n)) *
              cos((2 * x + 1) * v * pi / (2 * n));
        }
      }
      dct.add(sum);
    }
  }
  final ac = dct.sublist(1)..sort();
  final median = ac[ac.length ~/ 2];
  var hash = 0;
  for (var i = 0; i < 64; i++) {
    if (dct[i] > median) hash |= 1 << i;
  }
  return hash;
}

double sharpness(Float64List g, int w, int h) {
  const tiles = 8;
  var best = 0.0;
  for (var ty = 0; ty < tiles; ty++) {
    for (var tx = 0; tx < tiles; tx++) {
      final x0 = max(1, tx * w ~/ tiles),
          x1 = min(w - 1, (tx + 1) * w ~/ tiles);
      final y0 = max(1, ty * h ~/ tiles),
          y1 = min(h - 1, (ty + 1) * h ~/ tiles);
      var sum = 0.0, sq = 0.0, count = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = y * w + x;
          final l = g[i - 1] + g[i + 1] + g[i - w] + g[i + w] - 4 * g[i];
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

/// 파일 하나의 CPU 분석. Isolate에서 실행한다.
(String, int, double) analyze(Uint8List file, Uint8List rgba, int w, int h) {
  final g = gray(rgba);
  return (sha256.convert(file).toString(), phash(g, w, h), sharpness(g, w, h));
}

String mb(int bytes) => '${(bytes / 1048576).round()}MB';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1. 디코딩', (tester) async {
    await tester.runAsync(() async {
      final cases = <String, Future<Uint8List> Function()>{
        for (final n in [
          'small.jpg',
          'small.png',
          'small.heic',
          'rot6.jpg',
          'rot6.heic',
          'big.jpg',
          'big.heic',
        ])
          n: () => asset(n),
        'small.webp(generated)': () async {
          final png = img.decodePng(await asset('small.png'))!;
          return img.encodeWebP(png, lossless: true);
        },
      };
      for (final e in cases.entries) {
        try {
          final d = await decode(await e.value());
          final px = d.rgba;
          int red(int x, int y) => px[(y * d.w + x) * 4];
          report(
            'decode ${e.key}: ok src=${d.srcW}x${d.srcH} out=${d.w}x${d.h} '
            'leftR=${red(2, d.h ~/ 2)} rightR=${red(d.w - 3, d.h ~/ 2)} '
            'topR=${red(d.w ~/ 2, 2)} bottomR=${red(d.w ~/ 2, d.h - 3)}',
          );
        } catch (err) {
          report('decode ${e.key}: FAIL $err');
        }
      }
      try {
        final bytes = await asset('small.jpg');
        final size = await Isolate.run(() async {
          final d = await decode(bytes);
          return '${d.w}x${d.h}';
        });
        report('decode background-isolate: ok $size');
      } catch (err) {
        report('decode background-isolate: FAIL $err');
      }
    });
  });

  testWidgets('2. 스캔 벤치마크', timeout: Timeout.none, (tester) async {
    await tester.runAsync(() async {
      if (Platform.isMacOS &&
          const bool.fromEnvironment('NO_NAP', defaultValue: false)) {
        final on = await const MethodChannel('snapkeeper/activity')
            .invokeMethod<bool>('begin');
        report('bench activity token=$on');
      }
      final dir = await Directory.systemTemp.createTemp('snapkeeper_bench');
      final names = <String>[];
      for (final n in ['big.jpg', 'big.heic']) {
        try {
          await decode(await asset(n));
        } catch (_) {
          report('bench skip $n: 디코딩 불가');
          continue;
        }
        await File('${dir.path}/$n').writeAsBytes(await asset(n));
        names.add(n);
      }
      var next = 0, done = 0;
      final sw = Stopwatch()..start();
      report('bench start n=$_n workers=$_workers files=$names');
      Future<void> worker() async {
        while (next < _n) {
          final i = next++;
          final file = await File('${dir.path}/${names[i % names.length]}')
              .readAsBytes();
          final d = await decode(file);
          final rgba = d.rgba, w = d.w, h = d.h;
          await Isolate.run(() => analyze(file, rgba, w, h));
          done++;
          if (done % max(1, _n ~/ 10) == 0) {
            report(
              'bench $done/$_n ${sw.elapsedMilliseconds}ms '
              'rss=${mb(ProcessInfo.currentRss)} '
              'maxRss=${mb(ProcessInfo.maxRss)}',
            );
          }
        }
      }

      await Future.wait(List.generate(_workers, (_) => worker()));
      report(
        'bench done n=$_n ${sw.elapsedMilliseconds}ms '
        'perFile=${(sw.elapsedMilliseconds / _n).toStringAsFixed(1)}ms '
        'maxRss=${mb(ProcessInfo.maxRss)}',
      );
      await dir.delete(recursive: true);
    });
  });

  testWidgets('3. 휴지통', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('snapkeeper_trash');
      final file = File('${dir.path}/트래시 테스트.txt');
      await file.writeAsString('snapkeeper');
      try {
        final trashed = await _trash.invokeMethod<String>(
          'moveToTrash',
          file.path,
        );
        final gone = !file.existsSync();
        final inTrash = trashed != null && File(trashed).existsSync();
        report('trash move: gone=$gone inTrash=$inTrash at=$trashed');
        if (inTrash) {
          await File(trashed).rename(file.path);
          final same = await file.readAsString() == 'snapkeeper';
          report('trash restore: ok=$same');
        }
      } on PlatformException catch (e) {
        report('trash move: FAIL ${e.code} ${e.message}');
      }
      try {
        await _trash.invokeMethod<String>(
          'moveToTrash',
          '${dir.path}/없는파일.txt',
        );
        report('trash missing-file: 오류 없음 (예상과 다름)');
      } on PlatformException catch (e) {
        report('trash missing-file: 예상대로 실패 ${e.code}');
      }
      await dir.delete(recursive: true);
    });
  });
}
