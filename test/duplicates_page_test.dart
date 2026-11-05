import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/image_features.dart';
import 'package:snapkeeper/data/database.dart';
import 'package:snapkeeper/data/photo_scanner.dart';
import 'package:snapkeeper/ui/duplicates_page.dart';

import 'test_helpers.dart';

void main() {
  final sep = Platform.pathSeparator;
  final root = '$sep없는사진';
  late PhotoDatabase db;

  setUp(() => db = PhotoDatabase.memory());
  tearDown(() => db.dispose());

  /// 파일 없이 분석 결과만 DB에 넣는다. 썸네일은 대체 아이콘으로 보인다.
  void seed(Map<String, (String sha, int phash, int width)> photos) {
    db.sync(root, [
      for (final name in photos.keys)
        PhotoFile('$root$sep$name', 1024 * 1024, DateTime(2024)),
    ]);
    db.saveAnalyses({
      for (final MapEntry(key: name, value: (sha, phash, width))
          in photos.entries)
        '$root$sep$name': PhotoAnalysis(
          sha256: sha,
          features: ImageFeatures(phash, 0x808080, 40, 50, 100),
          width: width,
          height: width * 3 ~/ 4,
        ),
    });
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DuplicatesPage(db: db, folder: root),
      ),
    );
    await pumpUntilLoaded(tester);
  }

  List<bool?> checkboxes(WidgetTester tester) => [
    for (final c in tester.widgetList<Checkbox>(find.byType(Checkbox))) c.value,
  ];

  testWidgets('완전 동일은 추천 사진 외 나머지를 미리 선택한다', (tester) async {
    seed({
      'a.jpg': ('same', 1, 4000),
      'b.jpg': ('same', 1, 4000),
      'c.jpg': ('same', 1, 4000),
    });

    await open(tester);

    expect(find.textContaining('완전 동일 1그룹 · 거의 동일 0그룹'), findsOneWidget);
    expect(find.textContaining('2.0 MB 확보'), findsOneWidget);
    expect(find.text('남길 사진 추천'), findsOneWidget);
    expect(checkboxes(tester), [false, true, true]);
    expect(find.text('선택 2장 · 2.0 MB'), findsOneWidget);
  });

  testWidgets('거의 동일은 아무것도 미리 선택하지 않는다', (tester) async {
    seed({'big.jpg': ('x', 0xFF, 4000), 'small.jpg': ('y', 0xFE, 1000)});

    await open(tester);

    expect(find.textContaining('거의 동일 1그룹'), findsOneWidget);
    expect(find.textContaining('해시 차이 1'), findsOneWidget);
    expect(checkboxes(tester), [false, false]);
    expect(find.text('선택 0장 · 0 B'), findsOneWidget);
  });

  testWidgets('체크박스로 선택을 바꾼다', (tester) async {
    seed({'big.jpg': ('x', 0xFF, 4000), 'small.jpg': ('y', 0xFE, 1000)});
    await open(tester);

    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();

    expect(checkboxes(tester), [false, true]);
    expect(find.text('선택 1장 · 1.0 MB'), findsOneWidget);
  });

  testWidgets('보관한 그룹은 사라지고 다시 열어도 나오지 않는다', (tester) async {
    seed({'a.jpg': ('same', 1, 4000), 'b.jpg': ('same', 1, 4000)});
    await open(tester);

    await tester.tap(find.text('이 그룹 보관'));
    await tester.pump();

    expect(find.byType(Checkbox), findsNothing);
    expect(db.keptSha256(), {'same'});

    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(find.text('중복 사진이 없습니다.'), findsOneWidget);
  });

  testWidgets('중복이 없으면 안내한다', (tester) async {
    seed({'a.jpg': ('x', 0, 4000), 'b.jpg': ('y', -1, 4000)});

    await open(tester);

    expect(find.text('중복 사진이 없습니다.'), findsOneWidget);
  });
}
