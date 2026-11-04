// 품질 탐지 정확도 평가. 샘플 사진은 읽기만 하고 옮기거나 바꾸지 않는다.
//
// 샘플 폴더 구조 (폴더 이름이 정답):
//   <SAMPLES>/캡처/  <SAMPLES>/저화질/  <SAMPLES>/초점불량/  <SAMPLES>/정상/
//
// 실행:
//   flutter test tool/evaluate_quality.dart --dart-define=SAMPLES=/경로/샘플
//
// 정밀도는 "후보 중 정상 사진이 아닌 비율"로 잰다. 캡처 사진이 저화질로도 잡히는 것은
// 지워도 되는 사진이라 오탐으로 세지 않고, 따로 "다른 분류" 수로 보여 준다.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';
import 'package:snapkeeper/core/quality.dart';
import 'package:snapkeeper/core/thresholds.dart';
import 'package:snapkeeper/data/analyzer.dart';
import 'package:snapkeeper/data/photo_scanner.dart';

const _samples = String.fromEnvironment('SAMPLES');

const _labels = {
  '캡처': QualityIssue.screenshot,
  'screenshot': QualityIssue.screenshot,
  '저화질': QualityIssue.lowResolution,
  'lowres': QualityIssue.lowResolution,
  '초점불량': QualityIssue.blurry,
  'blurry': QualityIssue.blurry,
  '정상': null,
  'normal': null,
};

const _titles = {
  QualityIssue.screenshot: '캡처',
  QualityIssue.lowResolution: '저화질',
  QualityIssue.blurry: '초점 불량',
};

void main() {
  testWidgets('품질 탐지 정확도', timeout: Timeout.none, (tester) async {
    if (_samples.isEmpty) {
      print('SAMPLES를 지정하세요: --dart-define=SAMPLES=/경로/샘플');
      return;
    }
    final label = <String, QualityIssue?>{};
    final records = <PhotoRecord>[];
    await tester.runAsync(() async {
      for (final dir in Directory(_samples).listSync().whereType<Directory>()) {
        final name = fileName(dir.path);
        if (!_labels.containsKey(name.toLowerCase()) &&
            !_labels.containsKey(name)) {
          print('건너뜀: 알 수 없는 폴더 $name');
          continue;
        }
        final issue = _labels[name] ?? _labels[name.toLowerCase()];
        for (final f in scanPhotosSync(dir.path).photos) {
          final a = await analyzePhoto(f.path);
          if (a == null) continue;
          label[f.path] = issue;
          records.add(
            PhotoRecord(
              path: f.path,
              size: f.size,
              modified: f.modified,
              sha256: a.sha256,
              grayStd: a.features?.grayStd,
              sharpness: a.features?.sharpness,
              width: a.width,
              height: a.height,
              camera: a.camera,
              error: a.error,
            ),
          );
        }
      }
    });

    final counts = <QualityIssue?, int>{};
    for (final l in label.values) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
    print(
      '\n샘플 ${records.length}장: ${[for (final e in counts.entries) '${e.key == null ? '정상' : _titles[e.key]} ${e.value}'].join(', ')}',
    );
    final failed = records.where((r) => r.error != null).length;
    if (failed > 0) print('분석 실패 $failed장 (평가에서 제외됨)');

    final found = findQualityIssues(records);
    print('\n| 분류 | 후보 | 정답 | 놓침 | 정상인데 후보(오탐) | 다른 분류 | 정밀도 | 재현율 |');
    print('|---|---|---|---|---|---|---|---|');
    final details = StringBuffer();
    for (final issue in QualityIssue.values) {
      final predicted = {for (final c in found[issue]!) c.photo.path: c};
      final truth = {
        for (final e in label.entries)
          if (e.value == issue) e.key,
      };
      final tp = predicted.keys.where(truth.contains).length;
      final fp = predicted.keys.where((p) => label[p] == null).toList();
      final other = predicted.length - tp - fp.length;
      final missed = truth.where((p) => !predicted.containsKey(p)).toList();
      String pct(int a, int b) =>
          b == 0 ? '-' : '${(100 * a / b).toStringAsFixed(1)}%';
      print(
        '| ${_titles[issue]} | ${predicted.length} | $tp | ${missed.length} | '
        '${fp.length} | $other | ${pct(predicted.length - fp.length, predicted.length)} | '
        '${pct(tp, truth.length)} |',
      );

      details.writeln('\n## ${_titles[issue]}');
      for (final p in fp) {
        details.writeln('오탐: $p — ${predicted[p]!.reason}');
      }
      for (final p in missed) {
        final r = records.firstWhere((r) => r.path == p);
        details.writeln(
          '놓침: $p — ${r.width}×${r.height}, '
          '카메라 ${r.camera ?? '없음'}, 선명도 ${r.sharpness?.toStringAsFixed(1)}, '
          '밝기 편차 ${r.grayStd?.toStringAsFixed(1)}${r.error == null ? '' : ', 오류 ${r.error}'}',
        );
      }
    }

    // 초점 불량 기준을 고르기 위한 선명도 분포.
    List<double> sharpnessOf(QualityIssue? l) => [
      for (final r in records)
        if (label[r.path] == l && r.sharpness != null) r.sharpness!,
    ]..sort();
    String spread(List<double> v) {
      if (v.isEmpty) return '-';
      double q(double p) => v[((v.length - 1) * p).round()];
      return '최소 ${q(0).toStringAsFixed(1)} · 10% ${q(0.1).toStringAsFixed(1)} · '
          '중앙 ${q(0.5).toStringAsFixed(1)} · 90% ${q(0.9).toStringAsFixed(1)} · '
          '최대 ${q(1).toStringAsFixed(1)}';
    }

    print('\n선명도 분포 (현재 기준 ${blurryMaxSharpness.toStringAsFixed(0)} 미만):');
    print('  초점불량: ${spread(sharpnessOf(QualityIssue.blurry))}');
    print('  정상:     ${spread(sharpnessOf(null))}');
    print(details);
  });
}
