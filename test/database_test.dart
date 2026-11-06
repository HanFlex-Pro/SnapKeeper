import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
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
    features: ImageFeatures(42, 0x808080, 30, 50, 100),
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
        features: const ImageFeatures(-5, 0x112233, 12.5, 40.25, 100),
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

  test('v1 DB를 열면 v2로 바꾸고 모든 사진을 다시 분석한다', () {
    final temp = Directory.systemTemp.createTempSync('snapkeeper_migrate');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}${sep}v1.db';
    // v0.2에서 만든 DB와 같은 구조
    sqlite3.open(path)
      ..execute('''
        CREATE TABLE photos(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
          size_bytes INTEGER NOT NULL, modified_at INTEGER NOT NULL, sha256 TEXT,
          phash INTEGER, mean_rgb INTEGER, gray_std REAL, saturation REAL,
          width INTEGER, height INTEGER, taken_at INTEGER, camera TEXT,
          analysis_version INTEGER, error TEXT);
        CREATE INDEX photos_sha256 ON photos(sha256);
        CREATE TABLE kept_photos(sha256 TEXT PRIMARY KEY, kept_at INTEGER NOT NULL);
        CREATE TABLE folders(path TEXT PRIMARY KEY, bookmark TEXT, selected_at INTEGER NOT NULL);
        PRAGMA user_version = 1;
      ''')
      ..execute(
        'INSERT INTO photos(path, size_bytes, modified_at, sha256, analysis_version) VALUES (?, ?, ?, ?, 1)',
        [p('a.jpg'), 10, DateTime(2024).millisecondsSinceEpoch, 'old'],
      )
      ..execute('INSERT INTO kept_photos VALUES (?, ?)', ['kept', 1])
      ..close();

    final migrated = PhotoDatabase.open(path);
    addTearDown(migrated.dispose);

    expect(migrated.sync(root, [file('a.jpg')]), [p('a.jpg')]);
    expect(migrated.keptSha256(), {'kept'});
    migrated.saveAnalyses({
      p('a.jpg'): const PhotoAnalysis(
        sha256: 'new',
        features: ImageFeatures(1, 0, 30, 50, 123.5),
        latitude: 37.5,
        longitude: -122.25,
      ),
    });
    final r = migrated.records(root).single;
    expect((r.sharpness, r.latitude, r.longitude), (123.5, 37.5, -122.25));
    expect(migrated.sync(root, [file('a.jpg')]), isEmpty);
  });

  test('소수점 없는 실수도 읽는다', () {
    db.sync(root, [file('a.jpg')]);
    db.saveAnalyses({
      p('a.jpg'): const PhotoAnalysis(
        sha256: 'x',
        features: ImageFeatures(1, 0, 30, 50, 40),
        latitude: 37,
        longitude: 127,
      ),
    });

    final r = db.records(root).single;
    expect(
      (r.grayStd, r.saturation, r.sharpness, r.latitude),
      (30.0, 50.0, 40.0, 37.0),
    );
  });

  test('v2 DB를 열면 v3로 바꾸고 카메라 정보가 없는 사진만 다시 분석한다', () {
    final temp = Directory.systemTemp.createTempSync('snapkeeper_migrate3');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}${sep}v2.db';
    // v2 상태를 만든다: 최신 앱으로 만든 뒤 열 하나를 지우고 버전을 2로 되돌린다.
    PhotoDatabase.open(path)
      ..sync(root, [file('camera.jpg'), file('nocamera.png')])
      ..saveAnalyses({
        p('camera.jpg'): const PhotoAnalysis(sha256: 'a', camera: 'Canon'),
        p('nocamera.png'): const PhotoAnalysis(sha256: 'b'),
      })
      ..dispose();
    sqlite3.open(path)
      ..execute('ALTER TABLE photos DROP COLUMN screenshot_marker')
      ..execute('PRAGMA user_version = 2')
      ..close();

    final migrated = PhotoDatabase.open(path);
    addTearDown(migrated.dispose);

    expect(migrated.sync(root, [file('camera.jpg'), file('nocamera.png')]), [
      p('nocamera.png'),
    ]);
    migrated.saveAnalyses({
      p('nocamera.png'): const PhotoAnalysis(
        sha256: 'b',
        screenshotMarker: true,
      ),
    });
    final byName = {
      for (final r in migrated.records(root)) fileName(r.path): r,
    };
    expect(byName['nocamera.png']!.screenshotMarker, isTrue);
    expect(byName['camera.jpg']!.screenshotMarker, isNull);
  });
}
