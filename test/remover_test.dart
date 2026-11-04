import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';
import 'package:snapkeeper/data/database.dart';
import 'package:snapkeeper/data/photo_scanner.dart';
import 'package:snapkeeper/data/remover.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory root, trashDir;
  late PhotoDatabase db;
  final trashed = <String>[];

  /// 테스트용 휴지통: 파일을 별도 폴더로 옮긴다.
  Future<void> fakeTrash(String path) async {
    trashed.add(path);
    File(path).renameSync('${trashDir.path}$sep${fileName(path)}');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('snapkeeper_remove');
    trashDir = Directory.systemTemp.createTempSync('snapkeeper_trash');
    db = PhotoDatabase.memory();
    trashed.clear();
  });
  tearDown(() {
    db.dispose();
    root.deleteSync(recursive: true);
    trashDir.deleteSync(recursive: true);
  });

  /// 파일을 만들고 스캔·분석까지 끝낸 상태의 기록을 돌려준다.
  Map<String, PhotoRecord> setUpPhotos(List<String> names) {
    for (final n in names) {
      File('${root.path}$sep$n').writeAsStringSync('사진 $n');
    }
    final pending = db.sync(root.path, scanPhotosSync(root.path).photos);
    db.saveAnalyses({for (final p in pending) p: PhotoAnalysis(sha256: p)});
    return {for (final r in db.records(root.path)) fileName(r.path): r};
  }

  bool exists(String name) => File('${root.path}$sep$name').existsSync();

  test('고른 사진만 휴지통으로 옮기고 DB에서 지운다', () async {
    final photos = setUpPhotos(['a.jpg', 'b.jpg', 'c.jpg']);

    final result = await moveSelectedToTrash(db, [
      photos['a.jpg']!,
      photos['c.jpg']!,
    ], trash: fakeTrash);

    expect(result.moved.map((p) => fileName(p.path)), ['a.jpg', 'c.jpg']);
    expect(result.freedBytes, photos['a.jpg']!.size + photos['c.jpg']!.size);
    expect(
      [exists('a.jpg'), exists('b.jpg'), exists('c.jpg')],
      [false, true, false],
    );
    expect(trashDir.listSync(), hasLength(2));
    expect(db.records(root.path).map((r) => fileName(r.path)), ['b.jpg']);
  });

  test('스캔한 뒤 내용이 바뀐 파일은 건너뛴다', () async {
    final photos = setUpPhotos(['a.jpg']);
    File('${root.path}${sep}a.jpg').writeAsStringSync('편집한 사진, 크기도 다름');

    final result = await moveSelectedToTrash(db, [
      photos['a.jpg']!,
    ], trash: fakeTrash);

    expect(result.moved, isEmpty);
    expect(result.skipped.single.$2, '스캔한 뒤 파일이 바뀜');
    expect(trashed, isEmpty);
    expect(exists('a.jpg'), isTrue);
    expect(db.records(root.path), hasLength(1));
  });

  test('크기가 같아도 수정 시각이 바뀌면 건너뛴다', () async {
    final photos = setUpPhotos(['a.jpg']);
    File('${root.path}${sep}a.jpg').setLastModifiedSync(DateTime(2001));

    final result = await moveSelectedToTrash(db, [
      photos['a.jpg']!,
    ], trash: fakeTrash);

    expect(result.skipped.single.$2, '스캔한 뒤 파일이 바뀜');
    expect(trashed, isEmpty);
  });

  test('이미 없는 파일은 건너뛴다', () async {
    final photos = setUpPhotos(['a.jpg']);
    File('${root.path}${sep}a.jpg').deleteSync();

    final result = await moveSelectedToTrash(db, [
      photos['a.jpg']!,
    ], trash: fakeTrash);

    expect(result.skipped.single.$2, '파일이 이미 없음');
    expect(trashed, isEmpty);
  });

  test('휴지통 이동이 실패하면 파일과 DB를 그대로 두고 이유를 남긴다', () async {
    final photos = setUpPhotos(['a.jpg', 'b.jpg']);
    Future<void> failingTrash(String path) async {
      if (path.endsWith('a.jpg')) {
        throw FileSystemException('휴지통이 없는 볼륨', path);
      }
      await fakeTrash(path);
    }

    final result = await moveSelectedToTrash(db, [
      photos['a.jpg']!,
      photos['b.jpg']!,
    ], trash: failingTrash);

    expect(result.failed.single.$2, '휴지통이 없는 볼륨');
    expect(result.moved.map((p) => fileName(p.path)), ['b.jpg']);
    expect(exists('a.jpg'), isTrue);
    expect(db.records(root.path).map((r) => fileName(r.path)), ['a.jpg']);
  });

  test('아무것도 고르지 않으면 아무 일도 없다', () async {
    setUpPhotos(['a.jpg']);

    final result = await moveSelectedToTrash(db, [], trash: fakeTrash);

    expect(result.moved, isEmpty);
    expect(exists('a.jpg'), isTrue);
  });
}
