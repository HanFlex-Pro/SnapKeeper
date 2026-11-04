import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/photo_scanner.dart';
import 'package:snapkeeper/ui/viewer_page.dart';

void main() {
  final photos = [
    for (final name in ['a.jpg', 'b.jpg', 'c.jpg'])
      PhotoFile('/없는경로/$name', 1, DateTime(2024)),
  ];

  Future<void> openViewer(WidgetTester tester, int index) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ViewerPage(photos: photos, initialIndex: index),
              ),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  testWidgets('화살표 키로 이동하고 처음과 끝에서 멈춘다', (tester) async {
    await openViewer(tester, 0);
    expect(find.textContaining('a.jpg  ·  1 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.textContaining('1 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.textContaining('c.jpg  ·  3 / 3'), findsOneWidget);
  });

  testWidgets('버튼으로 이동하고 끝에서는 버튼이 비활성화된다', (tester) async {
    await openViewer(tester, 1);

    await tester.tap(find.byTooltip('다음 사진'));
    await tester.pump();
    expect(find.textContaining('3 / 3'), findsOneWidget);

    final next = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_right),
    );
    expect(next.onPressed, isNull);

    await tester.tap(find.byTooltip('이전 사진'));
    await tester.pump();
    expect(find.textContaining('2 / 3'), findsOneWidget);
  });

  testWidgets('Esc로 목록으로 돌아간다', (tester) async {
    await openViewer(tester, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ViewerPage), findsNothing);
    expect(find.text('열기'), findsOneWidget);
  });
}
