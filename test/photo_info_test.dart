import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/photo_info.dart';

// 테스트 이미지는 tool/make_test_fixtures.swift로 만든다.
void main() {
  Future<ExifFields> exifOf(String name) =>
      readExifFields(File('test/fixtures/$name').readAsBytesSync());

  test('JPEG에서 촬영일과 카메라를 읽는다', () async {
    final e = await exifOf('exif.jpg');
    final (takenAt, camera) = (e.takenAt, e.camera);

    expect(takenAt, DateTime(2023, 5, 1, 14, 30, 15));
    expect(camera, 'Canon EOS R6');
  });

  test('HEIC에서 촬영일과 카메라를 읽는다', () async {
    final e = await exifOf('exif.heic');
    final (takenAt, camera) = (e.takenAt, e.camera);

    expect(takenAt, DateTime(2023, 5, 1, 14, 30, 15));
    expect(camera, 'Canon EOS R6');
  });

  test('EXIF가 없으면 비워 둔다', () async {
    final e = await exifOf('plain.png');
    expect([
      e.takenAt,
      e.camera,
      e.latitude,
      e.longitude,
    ], everyElement(isNull));
  });

  test('이미지가 아닌 파일도 오류 없이 비워 둔다', () async {
    final e = await readExifFields(Uint8List.fromList([1, 2, 3]));
    expect([
      e.takenAt,
      e.camera,
      e.latitude,
      e.longitude,
    ], everyElement(isNull));
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

  test('JPEG에서 위치를 읽는다 (북위·동경)', () async {
    final e = await exifOf('exif.jpg');

    expect(e.latitude, closeTo(37.5665, 0.0001));
    expect(e.longitude, closeTo(126.978, 0.0001));
  });

  test('HEIC에서 위치를 읽는다 (서경은 음수)', () async {
    final e = await exifOf('exif.heic');

    expect(e.latitude, closeTo(37.7749, 0.0001));
    expect(e.longitude, closeTo(-122.4194, 0.0001));
  });

  test('도·분·초와 방향을 십진 도로 바꾼다', () {
    IfdRatios dms(int d, int m, int s100) =>
        IfdRatios([Ratio(d, 1), Ratio(m, 1), Ratio(s100, 100)]);

    expect(
      gpsDegrees(dms(33, 52, 760), 'S', max: 90),
      closeTo(-33.86878, 0.00001),
    );
    expect(
      gpsDegrees(dms(151, 12, 3348), 'E', max: 180),
      closeTo(151.2093, 0.0001),
    );
    expect(gpsDegrees(dms(91, 0, 0), 'N', max: 90), isNull);
    expect(
      gpsDegrees(
        IfdRatios([Ratio(1, 0), Ratio(0, 1), Ratio(0, 1)]),
        'N',
        max: 90,
      ),
      isNull,
    );
    expect(gpsDegrees(null, 'N', max: 90), isNull);
  });
}
