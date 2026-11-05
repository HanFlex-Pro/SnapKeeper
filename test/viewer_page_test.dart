import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/photo_scanner.dart';
import 'package:snapkeeper/ui/viewer_page.dart';

import 'test_helpers.dart';

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

  test('크기와 날짜 표시 형식', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatDate(DateTime(2023, 5, 1, 9, 3, 7)), '2023-05-01 09:03:07');
  });

  testWidgets('정보 패널에 파일 정보를 표시한다', (tester) async {
    final photo = PhotoFile(
      File('test/fixtures/exif.jpg').absolute.path,
      881,
      DateTime(2024, 1, 2, 3, 4, 5),
    );
    await tester.pumpWidget(
      MaterialApp(home: ViewerPage(photos: [photo], initialIndex: 0)),
    );
    for (
      var i = 0;
      i < 10 && find.text('Canon EOS R6').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    expect(find.text('exif.jpg'), findsOneWidget);
    expect(find.text('881 B'), findsOneWidget);
    expect(find.text('64 × 32'), findsOneWidget);
    expect(find.text('2023-05-01 14:30:15'), findsOneWidget);
    expect(find.text('Canon EOS R6'), findsOneWidget);
    expect(find.text('2024-01-02 03:04:05'), findsOneWidget);
  });

  testWidgets('이전·다음 사진을 미리 읽는다', (tester) async {
    final real = [
      for (final name in ['exif.jpg', 'scene_q90.jpg', 'scene_q40.jpg'])
        PhotoFile(File('test/fixtures/$name').absolute.path, 1, DateTime(2024)),
    ];
    await tester.pumpWidget(
      MaterialApp(home: ViewerPage(photos: real, initialIndex: 1)),
    );
    await tester.pump();

    final size = tester.view.physicalSize;
    final decodeSize = (size.width > size.height ? size.width : size.height)
        .round();
    Future<bool> tracked(int i) async {
      final key = await ResizeImage(
        FileImage(File(real[i].path)),
        width: decodeSize,
        height: decodeSize,
        policy: ResizeImagePolicy.fit,
      ).obtainKey(ImageConfiguration.empty);
      return !PaintingBinding.instance.imageCache.statusForKey(key).untracked;
    }

    expect(await tracked(0), isTrue);
    expect(await tracked(2), isTrue);
    await finishPendingIo(tester);
  });

  group('확대/축소', () {
    double scaleOf(WidgetTester tester) => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    ImageProvider shown(WidgetTester tester) =>
        tester.widget<Image>(find.byType(Image)).image;

    testWidgets('+로 확대하면 원본 해상도로 다시 읽고, 0으로 화면에 맞춘다', (tester) async {
      await openViewer(tester, 0);
      expect(shown(tester), isA<ResizeImage>());

      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
      expect(scaleOf(tester), closeTo(2, 0.001));
      expect(shown(tester), isA<FileImage>());

      await tester.sendKeyEvent(LogicalKeyboardKey.digit0, character: '0');
      await tester.pump();
      expect(scaleOf(tester), closeTo(1, 0.001));
    });

    testWidgets('배율은 8배까지, -로 줄이면 1배 아래로 내려가지 않는다', (tester) async {
      await openViewer(tester, 0);

      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      }
      await tester.pump();
      expect(scaleOf(tester), closeTo(8, 0.001));

      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
      }
      await tester.pump();
      expect(scaleOf(tester), closeTo(1, 0.001));
    });

    testWidgets('다른 사진으로 넘어가면 확대와 원본 해상도를 초기화한다', (tester) async {
      await openViewer(tester, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(find.textContaining('2 / 3'), findsOneWidget);
      expect(scaleOf(tester), closeTo(1, 0.001));
      expect(shown(tester), isA<ResizeImage>());
    });
  });
}
