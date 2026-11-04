import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';

PhotoRecord photo(
  String path, {
  String sha = 'a',
  int size = 100,
  int? phash = 0x0123456789ABCDEF,
  int meanRgb = 0x808080,
  double grayStd = 40,
  double saturation = 50,
  int width = 4000,
  int height = 3000,
  DateTime? takenAt,
  DateTime? modified,
}) => PhotoRecord(
  path: path,
  size: size,
  modified: modified ?? DateTime(2024),
  sha256: sha,
  phash: phash,
  meanRgb: meanRgb,
  grayStd: grayStd,
  saturation: saturation,
  width: width,
  height: height,
  takenAt: takenAt,
);

List<List<String>> paths(List<DuplicateGroup> groups, DuplicateKind kind) => [
  for (final g in groups)
    if (g.kind == kind) [for (final p in g.photos) p.path],
];

void main() {
  test('크기와 해시가 같으면 완전 동일', () {
    final groups = findDuplicates([
      photo('/a/IMG_1.jpg'),
      photo('/backup/IMG_1 copy.jpg'),
      photo('/c/다른.jpg', sha: 'b', phash: 0),
    ]);

    expect(paths(groups, DuplicateKind.exact), [
      ['/a/IMG_1.jpg', '/backup/IMG_1 copy.jpg'],
    ]);
    expect(groups.single.reclaimableBytes, 100);
  });

  test('해시가 같아도 크기가 다르면 완전 동일이 아님', () {
    final groups = findDuplicates([
      photo('/a.jpg', phash: null),
      photo('/b.jpg', size: 101, phash: null),
    ]);

    expect(groups, isEmpty);
  });

  test('남길 사진: 해상도 → 오래된 촬영일 → 짧은 경로 순', () {
    PhotoRecord first(List<PhotoRecord> ps) =>
        findDuplicates(ps).single.recommended;

    expect(
      first([photo('/small.jpg', width: 100, height: 100), photo('/big.jpg')])
          .path,
      '/big.jpg',
    );
    expect(
      first([
        photo('/new.jpg', takenAt: DateTime(2024)),
        photo('/old.jpg', takenAt: DateTime(2020)),
      ]).path,
      '/old.jpg',
    );
    expect(
      first([
        photo('/no_date.jpg', modified: DateTime(2019)),
        photo('/dated.jpg', takenAt: DateTime(2020)),
      ]).path,
      '/no_date.jpg',
    );
    expect(first([photo('/long/path/a.jpg'), photo('/a.jpg')]).path, '/a.jpg');
  });

  test('해시 차이가 작으면 거의 동일, 해상도가 높은 사진을 추천', () {
    final groups = findDuplicates([
      photo('/small.jpg', sha: 'x', width: 1000, height: 750),
      photo('/orig.jpg', sha: 'y', phash: 0x0123456789ABCDEF ^ 0x3),
    ]);

    expect(paths(groups, DuplicateKind.near), [
      ['/orig.jpg', '/small.jpg'],
    ]);
    expect(groups.single.reason, contains('해시 차이 2'));
  });

  test('거의 동일에서 제외되는 경우', () {
    List<DuplicateGroup> near(PhotoRecord other) =>
        findDuplicates([photo('/base.jpg', sha: 'base'), other])
            .where((g) => g.kind == DuplicateKind.near)
            .toList();

    // 해시 차이 3
    expect(
      near(photo('/far.jpg', sha: 'o', phash: 0x0123456789ABCDEF ^ 0x7)),
      isEmpty,
    );
    // 비율 다름 (크롭)
    expect(
      near(photo('/crop.jpg', sha: 'o', width: 3000, height: 3000)),
      isEmpty,
    );
    // 평균 색이 다름 (흑백본, 색 보정)
    expect(near(photo('/gray.jpg', sha: 'o', meanRgb: 0x606060)), isEmpty);
    // 흑백본 (평균 색은 비슷해도 채도가 다름)
    expect(near(photo('/bw.jpg', sha: 'o', saturation: 0)), isEmpty);
    // 평탄한 이미지
    expect(near(photo('/flat.jpg', sha: 'o', grayStd: 1)), isEmpty);
    // 분석되지 않은 사진
    expect(near(photo('/unknown.jpg', sha: 'o', phash: null)), isEmpty);
  });

  test('세로 사진과 가로 사진은 비율이 달라 묶지 않음', () {
    final groups = findDuplicates([
      photo('/land.jpg', sha: 'x'),
      photo('/port.jpg', sha: 'y', width: 3000, height: 4000),
    ]);

    expect(groups, isEmpty);
  });

  test('완전 동일 그룹은 거의 동일 비교에 추천 사진 한 장만 쓴다', () {
    final groups = findDuplicates([
      photo('/a.jpg', sha: 'same'),
      photo('/a_copy.jpg', sha: 'same'),
      photo('/a_small.jpg', sha: 'other', width: 1000, height: 750),
    ]);

    expect(paths(groups, DuplicateKind.exact), [
      ['/a.jpg', '/a_copy.jpg'],
    ]);
    expect(paths(groups, DuplicateKind.near), [
      ['/a.jpg', '/a_small.jpg'],
    ]);
  });

  test('보관한 사진과 해시가 없는 사진은 후보에서 뺀다', () {
    final groups = findDuplicates(
      [
        photo('/a.jpg', sha: 'kept'),
        photo('/b.jpg', sha: 'kept'),
        PhotoRecord(path: '/c.jpg', size: 100, modified: DateTime(2024)),
        PhotoRecord(path: '/d.jpg', size: 100, modified: DateTime(2024)),
      ],
      keptSha256: {'kept'},
    );

    expect(groups, isEmpty);
  });

  test('1만 장 그룹 계산이 빠르게 끝난다', () {
    final photos = [
      for (var i = 0; i < 10000; i++)
        photo(
          '/p$i.jpg',
          sha: 's${i ~/ 2}', // 2장씩 완전 동일
          phash: i * 0x9E3779B97F4A7C15,
        ),
    ];
    final sw = Stopwatch()..start();

    final groups = findDuplicates(photos);

    expect(paths(groups, DuplicateKind.exact), hasLength(5000));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
