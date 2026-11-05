import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/image_features.dart';
import 'package:snapkeeper/data/database.dart';
import 'package:snapkeeper/data/photo_scanner.dart';
import 'package:snapkeeper/ui/similar_page.dart';

import 'test_helpers.dart';

void main() {
  final sep = Platform.pathSeparator;
  final t0 = DateTime(2024, 5, 1, 12);
  late Directory root;
  late PhotoDatabase db;
  late List<String> trashed;

  setUp(() {
    root = Directory.systemTemp.createTempSync('snapkeeper_similar');
    db = PhotoDatabase.memory();
    trashed = [];
  });
  tearDown(() async {
    db.dispose();
    await deleteWithRetry(root);
  });

  /// 실제 파일을 만들고, 촬영 시각(초)과 선명도로 분석 결과를 넣는다.
  void seed(Map<String, ({int seconds, double sharpness})> photos) {
    for (final name in photos.keys) {
      File('${root.path}$sep$name').writeAsStringSync('사진 $name');
    }
    db.sync(root.path, scanPhotosSync(root.path).photos);
    db.saveAnalyses({
      for (final MapEntry(key: name, value: v) in photos.entries)
        '${root.path}$sep$name': PhotoAnalysis(
          sha256: name,
          features: ImageFeatures(0, 0x808080, 40, 50, v.sharpness),
          width: 4000,
          height: 3000,
          takenAt: t0.add(Duration(seconds: v.seconds)),
        ),
    });
  }

  Future<void> fakeTrash(String path) async {
    trashed.add(fileName(path));
    File(path).deleteSync(); // 테스트에서만. 실제 앱은 OS 휴지통으로 옮긴다.
  }

  Future<void> open(WidgetTester tester, {bool canTrash = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SimilarPage(
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

  Finder confirmButton() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, '휴지통으로 이동'),
  );

  final burst = {
    'a.jpg': (seconds: 0, sharpness: 50.0),
    'b.jpg': (seconds: 3, sharpness: 300.0),
    'c.jpg': (seconds: 6, sharpness: 120.0),
  };

  testWidgets('그룹과 베스트 컷을 보여 주고, 미리 선택하지 않는다', (tester) async {
    seed(burst);
    await open(tester);

    expect(find.textContaining('1그룹 · 베스트 컷만 남기면'), findsOneWidget);
    expect(find.textContaining('비슷한 사진 · 3장 · 6초 간격'), findsOneWidget);
    expect(find.text('베스트 컷 추천'), findsOneWidget);
    expect(find.text('b.jpg'), findsOneWidget); // 첫 타일(배지)이 가장 선명한 사진
    expect(checkboxes(tester), [false, false, false]);
  });

  testWidgets('베스트 컷 외 모두 선택', (tester) async {
    seed(burst);
    await open(tester);

    await tester.tap(find.text('베스트 컷 외 모두 선택'));
    await tester.pump();

    expect(checkboxes(tester), [false, true, true]);
    expect(find.textContaining('선택 2장'), findsOneWidget);
  });

  testWidgets('그룹을 보관하면 사라지고 다시 나오지 않는다', (tester) async {
    seed(burst);
    await open(tester);

    await tester.tap(find.text('이 그룹 보관'));
    await tester.pump();
    expect(find.byType(Checkbox), findsNothing);
    expect(db.keptSha256(), {'a.jpg', 'b.jpg', 'c.jpg'});

    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(find.text('비슷한 사진이 없습니다.'), findsOneWidget);
  });

  testWidgets('그룹 전체를 고르면 별도로 확인해야 옮길 수 있다', (tester) async {
    seed(burst);
    await open(tester);
    for (final box in find.byType(Checkbox).evaluate().toList()) {
      await tester.tap(find.byWidget(box.widget));
    }
    await tester.pump();

    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pumpAndSettle();

    expect(find.textContaining('하나도 남지 않습니다'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull);
  });

  testWidgets('고른 사진만 휴지통으로 옮긴다', (tester) async {
    seed(burst);
    await open(tester);
    await tester.tap(find.text('베스트 컷 외 모두 선택'));
    await tester.pump();

    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pumpAndSettle();
    expect(find.text('사진 2장을 휴지통으로 옮길까요?'), findsOneWidget);
    await tester.tap(confirmButton());
    await pumpUntilFound(tester, find.textContaining('옮겼습니다'));

    expect(trashed.toSet(), {'a.jpg', 'c.jpg'});
    expect(File('${root.path}${sep}b.jpg').existsSync(), isTrue);
  });

  testWidgets('비슷한 사진이 없으면 안내하고, 미지원 OS는 버튼 대신 안내', (tester) async {
    seed({
      'a.jpg': (seconds: 0, sharpness: 100.0),
      'far.jpg': (seconds: 600, sharpness: 100.0),
    });
    await open(tester);
    expect(find.text('비슷한 사진이 없습니다.'), findsOneWidget);

    seed(burst);
    await tester.pumpWidget(const SizedBox());
    await open(tester, canTrash: false);
    expect(find.text('휴지통으로 이동'), findsNothing);
    expect(find.textContaining('v0.5부터 지원'), findsOneWidget);
  });
}
