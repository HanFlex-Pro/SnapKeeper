import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/photo_scanner.dart';

void main() {
  late Directory root;
  final sep = Platform.pathSeparator;

  setUp(() => root = Directory.systemTemp.createTempSync('snapkeeper_scan'));
  tearDown(() => root.deleteSync(recursive: true));

  File touch(String relative, DateTime modified) {
    final file = File('${root.path}$sep${relative.replaceAll('/', sep)}')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    file.setLastModifiedSync(modified);
    return file;
  }

  List<String> names(ScanResult r) => r.photos.map((p) => p.name).toList();

  test('하위 폴더까지 지원 형식만 모은다 (확장자 대소문자 무시)', () {
    final t = DateTime(2024);
    touch('a.jpg', t);
    touch('sub/b.JPEG', t);
    touch('sub/deep/c.HeIc', t);
    touch('d.png', t);
    touch('e.webp', t);
    touch('notes.txt', t);
    touch('movie.mov', t);
    touch('noext', t);

    expect(names(scanPhotosSync(root.path)).toSet(), {
      'a.jpg',
      'b.JPEG',
      'c.HeIc',
      'd.png',
      'e.webp',
    });
  });

  test('숨김 파일과 숨김 폴더는 건너뛴다', () {
    final t = DateTime(2024);
    touch('._a.jpg', t);
    touch('.Trashes/b.jpg', t);
    touch('ok.jpg', t);

    expect(names(scanPhotosSync(root.path)), ['ok.jpg']);
  });

  test('최신 수정 순, 같으면 파일명 순으로 정렬한다', () {
    touch('old.jpg', DateTime(2020));
    touch('new.jpg', DateTime(2024));
    touch('b.jpg', DateTime(2022));
    touch('a.jpg', DateTime(2022));

    expect(names(scanPhotosSync(root.path)), [
      'new.jpg',
      'a.jpg',
      'b.jpg',
      'old.jpg',
    ]);
  });

  test('크기와 수정 시각을 담는다', () {
    touch('a.jpg', DateTime(2023, 5, 1));

    final photo = scanPhotosSync(root.path).photos.single;

    expect(photo.size, 1);
    expect(photo.modified, DateTime(2023, 5, 1));
  });

  test('심볼릭 링크는 따라가지 않는다', () {
    touch('real/a.jpg', DateTime(2024));
    try {
      Link('${root.path}${sep}loop').createSync(root.path);
      Link('${root.path}${sep}link.jpg').createSync('${root.path}${sep}real');
    } on FileSystemException {
      markTestSkipped('이 환경에서는 심볼릭 링크를 만들 수 없음');
      return;
    }

    expect(names(scanPhotosSync(root.path)), ['a.jpg']);
  });

  test('빈 폴더', () {
    final result = scanPhotosSync(root.path);

    expect(result.photos, isEmpty);
    expect(result.skippedFolders, 0);
  });

  test('없는 폴더는 건너뛴 폴더로 센다', () {
    final result = scanPhotosSync('${root.path}$sep없음');

    expect(result.photos, isEmpty);
    expect(result.skippedFolders, 1);
  });

  test('Isolate 버전도 같은 결과를 돌려준다', () async {
    touch('a.jpg', DateTime(2024));

    expect(names(await scanPhotos(root.path)), ['a.jpg']);
  });
}
