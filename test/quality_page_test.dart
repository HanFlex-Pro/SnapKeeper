import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/image_features.dart';
import 'package:snapkeeper/data/database.dart';
import 'package:snapkeeper/data/photo_scanner.dart';
import 'package:snapkeeper/ui/quality_page.dart';

import 'test_helpers.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory root;
  late PhotoDatabase db;
  late List<String> trashed;

  setUp(() {
    root = Directory.systemTemp.createTempSync('snapkeeper_quality');
    db = PhotoDatabase.memory();
    trashed = [];
  });
  tearDown(() async {
    db.dispose();
    await deleteWithRetry(root);
  });

  /// 실제 파일을 만들고, 분석 결과는 지정한 값으로 넣는다.
  void seed(
    Map<String, ({int w, int h, String? camera, double sharpness})> photos,
  ) {
    for (final name in photos.keys) {
      File('${root.path}$sep$name').writeAsStringSync('사진 $name');
    }
    db.sync(root.path, scanPhotosSync(root.path).photos);
    db.saveAnalyses({
      for (final MapEntry(key: name, value: v) in photos.entries)
        '${root.path}$sep$name': PhotoAnalysis(
          sha256: name,
          features: ImageFeatures(1, 0x808080, 40, 50, v.sharpness),
          width: v.w,
          height: v.h,
          camera: v.camera,
        ),
    });
  }

  const normal = (w: 4000, h: 3000, camera: 'Canon', sharpness: 500.0);

  Future<void> fakeTrash(String path) async {
    trashed.add(fileName(path));
    File(path).deleteSync(); // 테스트에서만. 실제 앱은 OS 휴지통으로 옮긴다.
  }

  Future<void> open(WidgetTester tester, {bool canTrash = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QualityPage(
          db: db,
          folder: root.path,
          trash: fakeTrash,
          canTrash: canTrash,
        ),
      ),
    );
    await pumpUntilLoaded(tester);
    await pumpUntilThumbnailsSettled(tester);
  }

  List<bool?> checkboxes(WidgetTester tester) => [
    for (final c in tester.widgetList<Checkbox>(find.byType(Checkbox))) c.value,
  ];

  testWidgets('탭마다 후보 수를 보여 주고, 미리 선택하지 않는다', (tester) async {
    seed({
      'Screenshot 1.png': (w: 1000, h: 800, camera: null, sharpness: 500),
      'tiny.jpg': (w: 320, h: 240, camera: null, sharpness: 500),
      'blurry.jpg': (w: 4000, h: 3000, camera: 'Canon', sharpness: 5),
      'good.jpg': normal,
    });

    await open(tester);

    expect(find.text('캡처 1장'), findsOneWidget);
    expect(find.text('저화질 1장'), findsOneWidget);
    expect(find.text('흐림·실수 1장'), findsOneWidget);
    expect(find.textContaining('파일명이 캡처 형식'), findsOneWidget);
    expect(checkboxes(tester), [false]);
    expect(find.text('선택 0장 · 0 B'), findsOneWidget);

    await tester.tap(find.text('흐림·실수 1장'));
    await tester.pumpAndSettle();
    expect(find.text('선명도 5, 기준 40 미만'), findsOneWidget);
  });

  testWidgets('전체 선택과 선택 해제', (tester) async {
    seed({
      'Screenshot 1.png': (w: 1000, h: 800, camera: null, sharpness: 500),
      'Screenshot 2.png': (w: 1000, h: 800, camera: null, sharpness: 500),
    });
    await open(tester);

    await tester.tap(find.text('전체 선택'));
    await tester.pump();
    expect(checkboxes(tester), [true, true]);
    expect(find.textContaining('선택 2장'), findsOneWidget);

    await tester.tap(find.text('선택 해제'));
    await tester.pump();
    expect(checkboxes(tester), [false, false]);
  });

  testWidgets('여러 탭에 나오는 사진은 한 번만 센다', (tester) async {
    // 캡처 파일명 + 저화질 + 흐림에 모두 해당
    seed({'Screenshot.png': (w: 320, h: 240, camera: null, sharpness: 3)});
    await open(tester);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    expect(find.textContaining('선택 1장'), findsOneWidget);
  });

  testWidgets('보관한 사진은 모든 탭에서 사라지고 다시 추천하지 않는다', (tester) async {
    seed({'Screenshot.png': (w: 320, h: 240, camera: null, sharpness: 3)});
    await open(tester);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('보관'));
    await pumpUntilLoaded(tester);

    expect(find.text('캡처 0장'), findsOneWidget);
    expect(find.text('저화질 0장'), findsOneWidget);
    expect(db.keptSha256(), {'Screenshot.png'});
  });

  testWidgets('고른 사진만 휴지통으로 옮긴다', (tester) async {
    seed({
      'Screenshot 1.png': (w: 1000, h: 800, camera: null, sharpness: 500),
      'Screenshot 2.png': (w: 1000, h: 800, camera: null, sharpness: 500),
    });
    await open(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pumpAndSettle();
    expect(find.text('사진 1장을 휴지통으로 옮길까요?'), findsOneWidget);
    expect(find.textContaining('하나도 남지 않습니다'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '휴지통으로 이동'),
      ),
    );
    await pumpUntilFound(tester, find.textContaining('옮겼습니다'));
    expect(trashed, hasLength(1));

    await tester.tap(find.text('확인'));
    await pumpUntilLoaded(tester);
    expect(find.text('캡처 1장'), findsOneWidget);
  });

  testWidgets('휴지통을 지원하지 않는 OS에서는 버튼 대신 안내', (tester) async {
    seed({'Screenshot.png': (w: 1000, h: 800, camera: null, sharpness: 500)});
    await open(tester, canTrash: false);

    expect(find.text('휴지통으로 이동'), findsNothing);
    expect(find.textContaining('v0.5부터 지원'), findsOneWidget);
  });
}
