import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';
import 'package:snapkeeper/core/quality.dart';

PhotoRecord photo(
  String path, {
  String? sha = 'x',
  int width = 4000,
  int height = 3000,
  String? camera = 'Canon EOS R6',
  double sharpness = 500,
  double grayStd = 40,
  String? error,
  DateTime? modified,
}) => PhotoRecord(
  path: path,
  size: 100,
  modified: modified ?? DateTime(2024),
  sha256: sha,
  width: width,
  height: height,
  camera: camera,
  sharpness: sharpness,
  grayStd: grayStd,
  error: error,
);

List<String> names(
  Map<QualityIssue, List<QualityCandidate>> r,
  QualityIssue i,
) => [for (final c in r[i]!) c.photo.path.split('/').last];

void main() {
  group('캡처', () {
    String? reason(String path, {String? camera, int w = 1000, int h = 800}) =>
        screenshotReason(photo(path, camera: camera, width: w, height: h));

    test('파일명이 캡처 형식이면 후보', () {
      for (final name in [
        'Screenshot 2024-01-01 at 10.00.00.png',
        'Screen Shot 2019-05-01.png',
        'Screenshot_20240101-101010_Chrome.jpg',
        '스크린샷 2024-01-01 오전 10.00.00.png',
        '화면 캡처 2024-01-01 100000.png',
        'SCR_20240101.jpg',
        'capture_001.jpg',
      ]) {
        expect(reason('/사진/$name'), contains('파일명'), reason: name);
      }
    });

    test('캡처 폴더 안이면 후보', () {
      expect(reason('/사진/Screenshots/IMG_1.jpg'), contains('캡처 폴더'));
      expect(reason(r'C:\사진\스크린샷\a.jpg'), contains('캡처 폴더'));
    });

    test('PNG이면서 화면 크기면 후보 (세로·가로 모두)', () {
      expect(reason('/a.png', w: 1170, h: 2532), contains('1170×2532'));
      expect(reason('/b.png', w: 2532, h: 1170), isNotNull);
      expect(reason('/c.png', w: 1171, h: 2532), isNull);
      expect(reason('/d.jpg', w: 1170, h: 2532), isNull); // JPEG는 크기만으로 판단하지 않음
    });

    test('카메라 EXIF가 있으면 파일명이 캡처 형식이어도 제외', () {
      expect(reason('/Screenshot.jpg', camera: 'Apple iPhone 15'), isNull);
    });

    test('평범한 사진은 후보가 아님', () {
      expect(reason('/사진/IMG_0001.jpg'), isNull);
      expect(reason('/사진/여행/바다.png'), isNull);
    });
  });

  group('저화질', () {
    test('0.5MP 미만이고 카메라 정보가 없으면 후보', () {
      final r = findQualityIssues([
        photo('/small.jpg', width: 640, height: 480, camera: null),
        photo('/edge.jpg', width: 1000, height: 500, camera: null), // 정확히 0.5MP
        photo('/old_camera.jpg', width: 640, height: 480), // 카메라 사진은 제외
        photo('/big.jpg', camera: null),
      ]);

      expect(names(r, QualityIssue.lowResolution), ['small.jpg']);
      expect(
        r[QualityIssue.lowResolution]!.single.reason,
        '640×480 (0.31MP), 기준 0.50MP 미만',
      );
    });

    test('작은 사진부터 보여 준다', () {
      final r = findQualityIssues([
        photo('/b.jpg', width: 600, height: 400, camera: null),
        photo('/a.jpg', width: 100, height: 100, camera: null),
      ]);

      expect(names(r, QualityIssue.lowResolution), ['a.jpg', 'b.jpg']);
    });
  });

  group('초점 불량', () {
    test('선명도가 기준 미만이면 후보, 흐린 순서대로', () {
      final r = findQualityIssues([
        photo('/sharp.jpg'),
        photo('/soft.jpg', sharpness: 30),
        photo('/blurry.jpg', sharpness: 5),
        photo('/edge.jpg', sharpness: 40),
      ]);

      expect(names(r, QualityIssue.blurry), ['blurry.jpg', 'soft.jpg']);
      expect(r[QualityIssue.blurry]!.first.reason, '선명도 5, 기준 40 미만');
    });

    test('평탄한 이미지(하늘, 단색)는 제외', () {
      final r = findQualityIssues([
        photo('/sky.jpg', sharpness: 2, grayStd: 3),
      ]);

      expect(r[QualityIssue.blurry], isEmpty);
    });
  });

  test('보관한 사진, 분석 전·실패 사진은 모든 분류에서 제외', () {
    final r = findQualityIssues(
      [
        photo('/kept_Screenshot.png', sha: 'kept', camera: null, sharpness: 1),
        photo('/pending_Screenshot.png', sha: null, camera: null),
        photo('/failed_Screenshot.heic', camera: null, error: '디코딩 실패'),
      ],
      keptSha256: {'kept'},
    );

    expect(r.values.every((list) => list.isEmpty), isTrue);
  });

  test('한 사진이 여러 분류에 나올 수 있다', () {
    final r = findQualityIssues([
      photo(
        '/Screenshot.png',
        width: 600,
        height: 400,
        camera: null,
        sharpness: 3,
      ),
    ]);

    expect(r.values.map((list) => list.length), [1, 1, 1]);
  });
}
