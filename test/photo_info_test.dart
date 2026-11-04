import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/photo_info.dart';

// 테스트 이미지는 tool/make_test_fixtures.swift로 만든다.
void main() {
  Future<(DateTime?, String?)> exifOf(String name) =>
      readExifFields(File('test/fixtures/$name').readAsBytesSync());

  test('JPEG에서 촬영일과 카메라를 읽는다', () async {
    final (takenAt, camera) = await exifOf('exif.jpg');

    expect(takenAt, DateTime(2023, 5, 1, 14, 30, 15));
    expect(camera, 'Canon EOS R6');
  });

  test('HEIC에서 촬영일과 카메라를 읽는다', () async {
    final (takenAt, camera) = await exifOf('exif.heic');

    expect(takenAt, DateTime(2023, 5, 1, 14, 30, 15));
    expect(camera, 'Canon EOS R6');
  });

  test('EXIF가 없으면 비워 둔다', () async {
    expect(await exifOf('plain.png'), (null, null));
  });

  test('이미지가 아닌 파일도 오류 없이 비워 둔다', () async {
    expect(await readExifFields(Uint8List.fromList([1, 2, 3])), (null, null));
  });

  test('EXIF 날짜 형식', () {
    expect(
      parseExifDate('2023:05:01 14:30:15'),
      DateTime(2023, 5, 1, 14, 30, 15),
    );
    expect(parseExifDate('0000:00:00 00:00:00'), isNull);
    expect(parseExifDate(''), isNull);
    expect(parseExifDate(null), isNull);
    expect(parseExifDate('어제'), isNull);
  });

  testWidgets('해상도를 읽는다', (tester) async {
    final info = await tester.runAsync(
      () => readPhotoInfo('test/fixtures/exif.jpg'),
    );

    expect((info!.width, info.height), (64, 32));
    expect(info.camera, 'Canon EOS R6');
  });
}
