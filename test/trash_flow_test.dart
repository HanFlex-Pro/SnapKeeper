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
  late Directory root;
  late PhotoDatabase db;
  late List<String> trashed;

  setUp(() {
    root = Directory.systemTemp.createTempSync('snapkeeper_flow');
    db = PhotoDatabase.memory();
    trashed = [];
  });
  tearDown(() async {
    db.dispose();
    await deleteWithRetry(root);
  });

  /// 실제 파일을 만들고, 분석 결과는 지정한 값으로 넣는다.
  void seed(Map<String, (String sha, int phash, int width)> photos) {
    for (final name in photos.keys) {
      File('${root.path}$sep$name').writeAsStringSync('사진 ${photos[name]!.$1}');
    }
    db.sync(root.path, scanPhotosSync(root.path).photos);
    db.saveAnalyses({
      for (final MapEntry(key: name, value: (sha, phash, width))
          in photos.entries)
        '${root.path}$sep$name': PhotoAnalysis(
          sha256: sha,
          features: ImageFeatures(phash, 0x808080, 40, 50, 100),
          width: width,
          height: width * 3 ~/ 4,
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
        home: DuplicatesPage(
          db: db,
          folder: root.path,
          trash: fakeTrash,
          canTrash: canTrash,
        ),
      ),
    );
    await pumpUntilLoaded(tester);
    // 썸네일이 파일을 다 읽을 때까지 기다린다. Windows는 읽는 중인 파일을 지울 수 없다.
    final thumbnails = find.byType(Checkbox).evaluate().length;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find.byIcon(Icons.broken_image_outlined).evaluate().length <
            thumbnails &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Finder confirmButton() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, '휴지통으로 이동'),
  );

  testWidgets('확인하면 고른 사진만 옮기고 결과를 보여 준다', (tester) async {
    seed({
      'a.jpg': ('same', 1, 4000),
      'b.jpg': ('same', 1, 4000),
      'c.jpg': ('other', -1, 4000),
    });
    await open(tester);

    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pumpAndSettle();
    expect(find.text('사진 1장을 휴지통으로 옮길까요?'), findsOneWidget);
    expect(find.textContaining('영구 삭제하지 않습니다'), findsOneWidget);

    await tester.tap(confirmButton());
    await pumpUntilFound(tester, find.textContaining('옮겼습니다'));

    expect(find.textContaining('1장을 휴지통으로 옮겼습니다'), findsOneWidget);
    expect(trashed, ['b.jpg']);
    expect(File('${root.path}${sep}a.jpg').existsSync(), isTrue);
    expect(File('${root.path}${sep}c.jpg').existsSync(), isTrue);

    await tester.tap(find.text('확인'));
    await pumpUntilLoaded(tester);
    expect(find.text('중복 사진이 없습니다.'), findsOneWidget);
  });

  testWidgets('취소하면 아무것도 옮기지 않는다', (tester) async {
    seed({'a.jpg': ('same', 1, 4000), 'b.jpg': ('same', 1, 4000)});
    await open(tester);

    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(trashed, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('그룹의 사진을 모두 고르면 별도로 확인해야 옮길 수 있다', (tester) async {
    seed({'a.jpg': ('same', 1, 4000), 'b.jpg': ('same', 1, 4000)});
    await open(tester);
    await tester.tap(find.byType(Checkbox).first); // 추천 사진까지 선택
    await tester.pump();

    await tester.tap(find.text('휴지통으로 이동'));
    await tester.pumpAndSettle();

    expect(find.textContaining('하나도 남지 않습니다'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull);

    await tester.tap(find.text('그룹의 사진을 모두 옮기는 것을 확인했습니다'));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNotNull);
  });

  testWidgets('두 그룹에 나오는 사진은 한 번만 센다', (tester) async {
    // a, b는 완전 동일. a(추천)와 small은 거의 동일.
    seed({
      'a.jpg': ('same', 0xFF, 4000),
      'b.jpg': ('same', 0xFF, 4000),
      'small.jpg': ('s', 0xFE, 1000),
    });
    await open(tester);
    // 완전 동일 그룹의 a와 거의 동일 그룹의 a는 같은 체크 상태를 공유한다.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.textContaining('선택 2장'), findsOneWidget);
  });

  testWidgets('휴지통을 지원하지 않는 OS에서는 버튼 대신 안내', (tester) async {
    seed({'a.jpg': ('same', 1, 4000), 'b.jpg': ('same', 1, 4000)});
    await open(tester, canTrash: false);

    expect(find.text('휴지통으로 이동'), findsNothing);
    expect(find.textContaining('v0.5부터 지원'), findsOneWidget);
  });
}
