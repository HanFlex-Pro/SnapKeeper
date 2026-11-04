import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/image_features.dart';
import 'package:snapkeeper/data/database.dart';
import 'package:snapkeeper/data/photo_scanner.dart';

void main() {
  final sep = Platform.pathSeparator;
  final root = '$sep사진';
  String p(String name) => '$root$sep$name';
  PhotoFile file(String name, {int size = 10, int day = 1}) =>
      PhotoFile(p(name), size, DateTime(2024, 1, day));
  const analysis = PhotoAnalysis(
    sha256: 'abc',
    features: ImageFeatures(42, 0x808080, 30, 50),
    width: 4000,
    height: 3000,
  );

  late PhotoDatabase db;
  setUp(() => db = PhotoDatabase.memory());
  tearDown(() => db.dispose());

  test('새 파일은 분석 대상', () {
    expect(db.sync(root, [file('a.jpg'), file('b.jpg')]), [
      p('a.jpg'),
      p('b.jpg'),
    ]);
  });

  test('분석한 파일은 다시 분석하지 않는다', () {
    db.sync(root, [file('a.jpg')]);
    db.saveAnalyses({p('a.jpg'): analysis});

    expect(db.sync(root, [file('a.jpg')]), isEmpty);
  });

  test('크기나 수정 시각이 바뀌면 분석 결과를 지우고 다시 분석', () {
    db.sync(root, [file('a.jpg'), file('b.jpg')]);
    db.saveAnalyses({p('a.jpg'): analysis, p('b.jpg'): analysis});

    expect(db.sync(root, [file('a.jpg', size: 11), file('b.jpg', day: 2)]), [
      p('a.jpg'),
      p('b.jpg'),
    ]);
    expect(db.records(root).every((r) => r.sha256 == null), isTrue);
  });

  test('분석하지 못하고 멈춘 파일은 다음 스캔에서 이어서 분석', () {
    db.sync(root, [file('a.jpg'), file('b.jpg')]);
    db.saveAnalyses({p('a.jpg'): analysis});

    expect(db.sync(root, [file('a.jpg'), file('b.jpg')]), [p('b.jpg')]);
  });

  test('디코딩에 실패한 파일도 다시 분석하지 않는다', () {
    db.sync(root, [file('a.heic')]);
    db.saveAnalyses({
      p('a.heic'): const PhotoAnalysis(sha256: 'x', error: '디코딩 실패'),
    });

    expect(db.sync(root, [file('a.heic')]), isEmpty);
    expect(db.records(root).single.sha256, 'x');
    expect(db.records(root).single.phash, isNull);
  });

  test('사라진 파일은 지운다', () {
    db.sync(root, [file('a.jpg'), file('b.jpg')]);
    db.sync(root, [file('a.jpg')]);

    expect(db.records(root).map((r) => r.path), [p('a.jpg')]);
  });

  test('분석 결과를 그대로 읽는다', () {
    db.sync(root, [file('a.jpg')]);
    db.saveAnalyses({
      p('a.jpg'): PhotoAnalysis(
        sha256: 'abc',
        features: const ImageFeatures(-5, 0x112233, 12.5, 40.25),
        width: 4000,
        height: 3000,
        takenAt: DateTime(2023, 5, 1, 14, 30),
        camera: 'Canon',
      ),
    });

    final r = db.records(root).single;
    expect(
      (r.sha256, r.phash, r.meanRgb, r.grayStd, r.saturation),
      ('abc', -5, 0x112233, 12.5, 40.25),
    );
    expect(
      (r.width, r.height, r.takenAt),
      (4000, 3000, DateTime(2023, 5, 1, 14, 30)),
    );
    expect((r.size, r.modified), (10, DateTime(2024, 1, 1)));
  });

  test('다른 폴더의 사진은 섞이지 않는다 (이름이 겹치는 폴더 포함)', () {
    db.sync(root, [file('a.jpg')]);
    final other = '${root}2';
    db.sync(other, [PhotoFile('$other${sep}b.jpg', 1, DateTime(2024))]);

    expect(db.records(root).map((r) => r.path), [p('a.jpg')]);
    db.sync(root, []);
    expect(db.records(other), hasLength(1));
  });

  test('사진 하나를 지운다', () {
    db.sync(root, [file('a.jpg'), file('b.jpg')]);
    db.removePhoto(p('a.jpg'));

    expect(db.records(root).map((r) => r.path), [p('b.jpg')]);
  });

  test('보관한 사진', () {
    db.keep(['x', 'y']);
    db.keep(['x']);

    expect(db.keptSha256(), {'x', 'y'});
  });

  test('마지막으로 고른 폴더를 기억한다', () {
    expect(db.lastFolder(), isNull);
    db.saveFolder('/a', 'bm1');
    db.saveFolder('/b', null);
    expect(db.lastFolder(), (path: '/b', bookmark: null));
    db.saveFolder('/a', 'bm2');
    expect(db.lastFolder(), (path: '/a', bookmark: 'bm2'));
  });

  group('settings.json 이전', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('snapkeeper_db'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('폴더와 북마크를 옮기고 파일을 지운다', () {
      final f = File('${temp.path}/settings.json')
        ..writeAsStringSync('{"folderPath":"/사진","bookmark":"bm"}');

      db.importLegacySettings(f);

      expect(db.lastFolder(), (path: '/사진', bookmark: 'bm'));
      expect(f.existsSync(), isFalse);
    });

    test('깨진 파일은 지우기만 한다', () {
      final f = File('${temp.path}/settings.json')..writeAsStringSync('{깨진');

      db.importLegacySettings(f);

      expect(db.lastFolder(), isNull);
      expect(f.existsSync(), isFalse);
    });

    test('파일이 없으면 아무것도 하지 않는다', () {
      db.importLegacySettings(File('${temp.path}/없음.json'));

      expect(db.lastFolder(), isNull);
    });
  });

  test('파일로 연 DB는 다시 열어도 내용이 남는다', () {
    final temp = Directory.systemTemp.createTempSync('snapkeeper_db');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}${sep}test.db';
    PhotoDatabase.open(path)
      ..saveFolder('/a', null)
      ..dispose();

    final reopened = PhotoDatabase.open(path);
    addTearDown(reopened.dispose);
    expect(reopened.lastFolder()?.path, '/a');
  });
}
