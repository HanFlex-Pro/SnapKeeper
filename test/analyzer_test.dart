import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';
import 'package:snapkeeper/data/analyzer.dart';
import 'package:snapkeeper/data/database.dart';
import 'package:snapkeeper/data/photo_scanner.dart';

import 'test_helpers.dart';

void main() {
  late Directory root;
  late PhotoDatabase db;
  final sep = Platform.pathSeparator;

  setUp(() {
    root = Directory.systemTemp.createTempSync('snapkeeper_analyze');
    db = PhotoDatabase.memory();
  });
  tearDown(() async {
    db.dispose();
    await deleteWithRetry(root);
  });

  void copyFixture(String fixture, String as) =>
      File('test/fixtures/$fixture').copySync('${root.path}$sep$as');

  Future<List<PhotoRecord>> scanAndAnalyze(WidgetTester tester) async {
    await tester.runAsync(() async {
      final pending = db.sync(root.path, scanPhotosSync(root.path).photos);
      await analyzePhotos(db, pending, batchSize: 2);
    });
    return db.records(root.path)..sort((a, b) => a.path.compareTo(b.path));
  }

  testWidgets('해시, 특징, 해상도, EXIF를 저장한다', (tester) async {
    copyFixture('exif.jpg', 'a.jpg');

    final r = (await scanAndAnalyze(tester)).single;

    expect(r.sha256, hasLength(64));
    expect(r.phash, isNotNull);
    expect((r.width, r.height), (64, 32));
    expect(r.takenAt, DateTime(2023, 5, 1, 14, 30, 15));
  });

  testWidgets('이름만 다른 복사본과 화질만 다른 사진을 찾는다', (tester) async {
    copyFixture('scene_q90.jpg', 'IMG_0001.jpg');
    copyFixture('scene_q90.jpg', 'IMG_0001 복사본.jpg');
    copyFixture('scene_q40.jpg', '압축본.jpg');
    copyFixture('exif.jpg', '다른사진.jpg');

    final groups = findDuplicates(await scanAndAnalyze(tester));
    List<String> names(DuplicateKind k) => [
      for (final p in groups.singleWhere((g) => g.kind == k).photos)
        fileName(p.path),
    ];

    expect(names(DuplicateKind.exact), ['IMG_0001.jpg', 'IMG_0001 복사본.jpg']);
    expect(
      names(DuplicateKind.near),
      unorderedEquals(['IMG_0001.jpg', '압축본.jpg']),
    );
  });

  testWidgets('디코딩할 수 없는 파일은 해시만 저장하고 오류를 기록한다', (tester) async {
    File('${root.path}${sep}broken.jpg').writeAsStringSync('이미지 아님');

    final r = (await scanAndAnalyze(tester)).single;

    expect(r.sha256, isNotNull);
    expect(r.phash, isNull);
    expect(db.sync(root.path, scanPhotosSync(root.path).photos), isEmpty);
  });

  testWidgets('취소하면 남은 파일은 다음 스캔에서 이어서 분석한다', (tester) async {
    for (var i = 0; i < 6; i++) {
      copyFixture('exif.jpg', 'p$i.jpg');
    }
    final listed = scanPhotosSync(root.path).photos;
    var analyzed = 0;

    await tester.runAsync(() async {
      final pending = db.sync(root.path, listed);
      await analyzePhotos(
        db,
        pending,
        workers: 1,
        batchSize: 1,
        onProgress: (done, _) => analyzed = done,
        isCancelled: () => analyzed >= 2,
      );
    });

    expect(analyzed, 2);
    expect(db.sync(root.path, listed), hasLength(4));
  });

  testWidgets('분석 중 사라진 파일은 건너뛴다', (tester) async {
    copyFixture('exif.jpg', 'a.jpg');
    final pending = db.sync(root.path, scanPhotosSync(root.path).photos);
    File('${root.path}${sep}a.jpg').deleteSync();

    final unreadable = await tester.runAsync(() => analyzePhotos(db, pending));

    expect(unreadable, 1);
    expect(db.records(root.path).single.sha256, isNull);
  });

  testWidgets('카메라 정보가 없는 사진의 캡처 표시를 저장한다', (tester) async {
    final png = File('test/fixtures/plain.png').readAsBytesSync();
    // 실제 iPhone 캡처처럼 XMP에 표시를 넣는다 (PNG 끝에 붙여도 앞 256KB 안이면 찾는다).
    File('${root.path}${sep}IMG_0001.PNG').writeAsBytesSync([
      ...png,
      ...'<exif:UserComment>Screenshot</exif:UserComment>'.codeUnits,
    ]);
    copyFixture('plain.png', 'plain.png');
    copyFixture('exif.jpg', 'camera.jpg');

    final byName = {
      for (final r in await scanAndAnalyze(tester)) fileName(r.path): r,
    };

    expect(byName['IMG_0001.PNG']!.screenshotMarker, isTrue);
    expect(byName['plain.png']!.screenshotMarker, isFalse);
    expect(byName['camera.jpg']!.screenshotMarker, isFalse);
  });
}
