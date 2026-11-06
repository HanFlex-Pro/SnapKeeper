// 정답 없이 실제 사진 폴더의 분석 값 분포를 보고, 임시 기준값이 크게 빗나갔는지 판단한다.
// 사진은 읽기만 하고 옮기거나 바꾸지 않으며, 앱 DB도 쓰지 않는다.
//
//   flutter test tool/report_distribution.dart --dart-define=PHOTOS=/경로/사진폴더
//
// 출력에 파일 이름 예시가 들어가므로 결과를 저장소에 올리지 않는다.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';
import 'package:snapkeeper/core/quality.dart';
import 'package:snapkeeper/core/similar.dart';
import 'package:snapkeeper/core/thresholds.dart';
import 'package:snapkeeper/data/analyzer.dart';
import 'package:snapkeeper/data/photo_scanner.dart';

const _photos = String.fromEnvironment('PHOTOS');

/// 지정하면 사진별 분석값을 CSV로 내보낸다. 저장소 밖 경로를 쓴다.
const _csv = String.fromEnvironment('CSV');

/// 지정하면 진행 상황을 이 파일에 덧붙여 쓴다(긴 실행을 지켜보기 위해).
const _progress = String.fromEnvironment('PROGRESS');

void main() {
  testWidgets('분석 값 분포', timeout: Timeout.none, (tester) async {
    if (_photos.isEmpty) {
      print('PHOTOS를 지정하세요: --dart-define=PHOTOS=/경로/사진폴더');
      return;
    }
    final listed = scanPhotosSync(_photos).photos;
    final records = <PhotoRecord>[];
    final sw = Stopwatch()..start();
    var unreadable = 0;
    void progress(String line) {
      if (_progress.isNotEmpty) {
        File(_progress).writeAsStringSync('$line\n', mode: FileMode.append);
      }
    }

    progress('목록 ${listed.length}장');
    await tester.runAsync(() async {
      var next = 0, done = 0;
      Future<void> worker() async {
        while (next < listed.length) {
          final f = listed[next++];
          final a = await analyzePhoto(f.path);
          if (++done % 2000 == 0) {
            progress(
              '${DateTime.now().toIso8601String().substring(11, 19)} $done/${listed.length}',
            );
          }
          if (a == null) {
            unreadable++;
            continue;
          }
          records.add(
            PhotoRecord(
              path: f.path,
              size: f.size,
              modified: f.modified,
              sha256: a.sha256,
              phash: a.features?.phash,
              meanRgb: a.features?.meanRgb,
              grayStd: a.features?.grayStd,
              saturation: a.features?.saturation,
              sharpness: a.features?.sharpness,
              width: a.width,
              height: a.height,
              takenAt: a.takenAt,
              camera: a.camera,
              latitude: a.latitude,
              longitude: a.longitude,
              error: a.error,
            ),
          );
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
    });
    final n = records.length;
    progress('분석 끝 $n장, 읽지 못함 $unreadable장');

    // 캡처 판정 보강용: 카메라 정보가 없는 사진의 앞부분에서 "Screenshot" 표시를 찾는다.
    // iPhone 캡처는 EXIF 사용자 메모와 XMP에 "Screenshot"을 남긴다. exif 패키지는 PNG 안의
    // EXIF를 읽지 못해 바이트에서 직접 찾는다.
    final comment = <String, String>{};
    final markers = [
      ascii.encode('ASCII\u0000\u0000\u0000Screenshot'),
      ascii.encode('<exif:UserComment>Screenshot<'),
    ];
    bool contains(Uint8List hay, List<int> needle) {
      outer:
      for (var i = 0; i + needle.length <= hay.length; i++) {
        for (var j = 0; j < needle.length; j++) {
          if (hay[i + j] != needle[j]) continue outer;
        }
        return true;
      }
      return false;
    }

    await tester.runAsync(() async {
      for (final r in records.where((r) => r.camera == null)) {
        try {
          final file = await File(r.path).open();
          final head = await file.read(256 * 1024);
          await file.close();
          comment[r.path] = markers.any((m) => contains(head, m))
              ? 'Screenshot'
              : '';
        } catch (_) {}
      }
    });
    String pct(int k) => '$k장 (${(100 * k / max(1, n)).toStringAsFixed(1)}%)';
    String name(PhotoRecord r) => r.path.substring(_photos.length + 1);

    print('\n# 기본');
    print(
      '사진 ${listed.length}장 중 분석 $n장, 읽지 못함 $unreadable장, ${sw.elapsed.inSeconds}초',
    );
    print('분석 실패 ${pct(records.where((r) => r.error != null).length)}');
    print('카메라 정보 있음 ${pct(records.where((r) => r.camera != null).length)}');
    print('촬영일 있음 ${pct(records.where((r) => r.takenAt != null).length)}');
    print('위치 있음 ${pct(records.where((r) => r.latitude != null).length)}');

    final found = findQualityIssues(records);

    print('\n# 캡처');
    final shots = found[QualityIssue.screenshot]!;
    print('후보 ${pct(shots.length)}');
    final byReason = <String, int>{};
    for (final c in shots) {
      byReason[c.reason.split(',').first] =
          (byReason[c.reason.split(',').first] ?? 0) + 1;
    }
    byReason.forEach((k, v) => print('  $k: $v장'));
    for (final c in shots.take(10)) {
      print('  예: ${name(c.photo)} — ${c.reason}');
    }

    print('\n# 저화질 (기준 ${lowResolutionMaxPixels ~/ 1000}K 화소 미만, 카메라 정보 없음)');
    final low = found[QualityIssue.lowResolution]!;
    print('후보 ${pct(low.length)}');
    final smallWithCamera = records
        .where(
          (r) =>
              r.camera != null &&
              r.pixels > 0 &&
              r.pixels < lowResolutionMaxPixels,
        )
        .length;
    print('카메라 정보 때문에 제외된 저해상도 사진 $smallWithCamera장');
    for (final c in low.take(10)) {
      print('  예: ${name(c.photo)} — ${c.reason}');
    }

    print(
      '\n# 초점 불량 (기준 선명도 ${blurryMaxSharpness.toStringAsFixed(0)} 미만, 평탄 제외)',
    );
    final sharp = [
      for (final r in records)
        if (r.sharpness != null && (r.grayStd ?? 0) >= flatImageMaxGrayStd)
          r.sharpness!,
    ]..sort();
    final flat = records
        .where(
          (r) => r.sharpness != null && (r.grayStd ?? 0) < flatImageMaxGrayStd,
        )
        .length;
    double q(double p) =>
        sharp.isEmpty ? 0 : sharp[((sharp.length - 1) * p).round()];
    print('평탄해서 제외 $flat장');
    print(
      '선명도 백분위: ${[
        for (final p in [0.01, 0.05, 0.10, 0.25, 0.50, 0.75]) '${(p * 100).round()}%=${q(p).toStringAsFixed(1)}',
      ].join(', ')}',
    );
    for (final t in [10, 20, 40, 80, 120, 200]) {
      print('  선명도 $t 미만: ${pct(sharp.where((s) => s < t).length)}');
    }
    final blurry = found[QualityIssue.blurry]!;
    print('후보 ${pct(blurry.length)}');
    for (final c in blurry.take(10)) {
      print('  가장 흐린 예: ${name(c.photo)} — ${c.reason}');
    }

    print(
      '\n# 비슷한 사진 (현재 기준 $similarMaxSeconds초, 해시 $similarMaxHamming, ${similarMaxMeters.toStringAsFixed(0)}m)',
    );
    for (final s in [30, 60, 120]) {
      final row = <String>[];
      for (final h in [8, 12, 16]) {
        final groups = findSimilarGroups(records, maxSeconds: s, maxHamming: h);
        final grouped = groups.fold(0, (sum, g) => sum + g.photos.length);
        row.add(
          '해시$h: ${groups.length}그룹/${(100 * grouped / max(1, n)).toStringAsFixed(1)}%',
        );
      }
      print('  $s초 — ${row.join(' · ')}');
    }
    final groups = findSimilarGroups(records);
    final sizes = <int, int>{};
    for (final g in groups) {
      final k = min(g.photos.length, 10);
      sizes[k] = (sizes[k] ?? 0) + 1;
    }
    print(
      '현재 기준 그룹 크기: ${(sizes.keys.toList()..sort()).map((k) => '${k == 10 ? '10+' : k}장 ${sizes[k]}그룹').join(', ')}',
    );
    for (final g in groups.take(8)) {
      print('  예: ${g.photos.map(name).join(', ')} — ${g.reason}');
    }

    final dups = findDuplicates(records);

    if (_csv.isNotEmpty) {
      final similarOf = <String, int>{};
      for (var i = 0; i < groups.length; i++) {
        for (final p in groups[i].photos) {
          similarOf[p.path] = i;
        }
      }
      final nearOf = <String, int>{};
      final near = dups.where((g) => g.kind == DuplicateKind.near).toList();
      for (var i = 0; i < near.length; i++) {
        for (final p in near[i].photos) {
          nearOf[p.path] = i;
        }
      }
      final shotPaths = {for (final c in shots) c.photo.path};
      final lowPaths = {for (final c in low) c.photo.path};
      final lines = [
        'path,sharpness,gray_std,width,height,taken_at,phash,similar_group,near_group,screenshot,camera,location,lowres,error,mean_rgb,saturation,comment',
        for (final r in records)
          [
            '"${r.path}"',
            r.sharpness?.toStringAsFixed(1) ?? '',
            r.grayStd?.toStringAsFixed(1) ?? '',
            r.width ?? '',
            r.height ?? '',
            r.takenAt?.toIso8601String() ?? '',
            r.phash ?? '',
            similarOf[r.path] ?? '',
            nearOf[r.path] ?? '',
            shotPaths.contains(r.path) ? 1 : 0,
            r.camera == null ? 0 : 1,
            r.latitude == null ? 0 : 1,
            lowPaths.contains(r.path) ? 1 : 0,
            r.error == null ? 0 : 1,
            r.meanRgb ?? '',
            r.saturation?.toStringAsFixed(1) ?? '',
            '"${comment[r.path] ?? ''}"',
          ].join(','),
      ];
      File(_csv).writeAsStringSync('${lines.join('\n')}\n');
      print('\nCSV ${records.length}행 → $_csv');
    }
    print('\n# 참고: 중복');
    print(
      '완전 동일 ${dups.where((g) => g.kind == DuplicateKind.exact).length}그룹, '
      '거의 동일 ${dups.where((g) => g.kind == DuplicateKind.near).length}그룹',
    );
  });
}
