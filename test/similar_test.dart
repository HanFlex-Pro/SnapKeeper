import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/core/duplicates.dart';
import 'package:snapkeeper/core/similar.dart';

final t0 = DateTime(2024, 5, 1, 12);

PhotoRecord photo(
  String name, {
  int seconds = 0,
  int phash = 0,
  String? sha,
  double sharpness = 100,
  int width = 4000,
  double? lat,
  double? lon,
  bool withDate = true,
  String? error,
}) => PhotoRecord(
  path: '/p/$name',
  size: 100,
  modified: DateTime(2024),
  sha256: sha ?? name,
  phash: phash,
  width: width,
  height: width * 3 ~/ 4,
  takenAt: withDate ? t0.add(Duration(seconds: seconds)) : null,
  sharpness: sharpness,
  latitude: lat,
  longitude: lon,
  error: error,
);

/// 하위 [bits]개 비트를 켠 해시 (해밍 거리 = bits).
int bits(int n) => (1 << n) - 1;

List<List<String>> names(List<DuplicateGroup> groups) => [
  for (final g in groups) [for (final p in g.photos) p.path.substring(3)],
];

void main() {
  test('시각과 구도가 가까우면 묶고, 선명한 사진을 베스트 컷으로 추천한다', () {
    final groups = findSimilarGroups([
      photo('a.jpg', sharpness: 50),
      photo('b.jpg', seconds: 5, phash: bits(3), sharpness: 300),
      photo('c.jpg', seconds: 9, phash: bits(6), sharpness: 120),
    ]);

    expect(names(groups), [
      ['b.jpg', 'c.jpg', 'a.jpg'],
    ]);
    expect(groups.single.kind, DuplicateKind.similar);
    expect(groups.single.reason, '9초 간격, 구도 유사 (해시 차이 최대 6)');
    expect(groups.single.reclaimableBytes, 200);
  });

  test('경계값: 60초·해시 차이 12는 포함, 넘으면 새 그룹', () {
    expect(
      names(findSimilarGroups([photo('a.jpg'), photo('b.jpg', seconds: 60)])),
      hasLength(1),
    );
    expect(
      findSimilarGroups([photo('a.jpg'), photo('b.jpg', seconds: 61)]),
      isEmpty,
    );
    expect(
      names(
        findSimilarGroups([photo('a.jpg'), photo('b.jpg', phash: bits(12))]),
      ),
      hasLength(1),
    );
    expect(
      findSimilarGroups([photo('a.jpg'), photo('b.jpg', phash: bits(13))]),
      isEmpty,
    );
  });

  test('둘 다 위치가 있으면 100m 안이어야 묶는다', () {
    // 위도 0.001도 ≈ 111m
    final near = photo('b.jpg', seconds: 5, lat: 37.5005, lon: 127.0);
    final far = photo('c.jpg', seconds: 5, lat: 37.501, lon: 127.0);
    final base = photo('a.jpg', lat: 37.5, lon: 127.0);

    expect(findSimilarGroups([base, near]), hasLength(1));
    expect(findSimilarGroups([base, far]), isEmpty);
    // 한쪽만 위치가 있으면 위치는 보지 않는다.
    expect(findSimilarGroups([photo('a.jpg'), far]), hasLength(1));
  });

  test('그룹 첫 사진과 비교해 이어 붙지 않는다', () {
    // a–b 40초, b–c 40초: c는 a와 80초라 새 그룹. d가 c와 묶인다.
    final groups = findSimilarGroups([
      photo('a.jpg'),
      photo('b.jpg', seconds: 40),
      photo('c.jpg', seconds: 80),
      photo('d.jpg', seconds: 100),
    ]);

    expect(names(groups).map((g) => g.toSet()).toList(), [
      {'a.jpg', 'b.jpg'},
      {'c.jpg', 'd.jpg'},
    ]);
  });

  test('구도가 달라 묶이지 않은 사진은 다음 그룹의 시작이 된다', () {
    final groups = findSimilarGroups([
      photo('a.jpg'),
      photo('other.jpg', seconds: 2, phash: -1),
      photo('other2.jpg', seconds: 4, phash: -1),
    ]);

    expect(names(groups).single.toSet(), {'other.jpg', 'other2.jpg'});
  });

  test('촬영일 없음, 분석 실패, 보관한 사진은 뺀다', () {
    final groups = findSimilarGroups(
      [
        photo('a.jpg'),
        photo('no_date.jpg', seconds: 1, withDate: false),
        photo('failed.jpg', seconds: 2, error: '디코딩 실패'),
        photo('kept.jpg', seconds: 3),
      ],
      keptSha256: {'kept.jpg'},
    );

    expect(groups, isEmpty);
  });

  test('완전 동일 사진은 대표 한 장만 쓴다', () {
    final groups = findSimilarGroups([
      photo('a.jpg', sha: 'same'),
      photo('a_copy.jpg', sha: 'same'),
      photo('b.jpg', seconds: 3),
    ]);

    expect(names(groups).single.toSet(), {'a.jpg', 'b.jpg'});
  });

  test('선명도가 같으면 해상도가 높은 사진이 베스트 컷', () {
    final groups = findSimilarGroups([
      photo('small.jpg', width: 1000),
      photo('big.jpg', seconds: 1),
    ]);

    expect(groups.single.recommended.path, '/p/big.jpg');
  });

  test('거리 계산', () {
    expect(distanceMeters(37.5, 127, 37.5, 127), 0);
    expect(distanceMeters(37.5, 127, 37.501, 127), closeTo(111.2, 0.5));
    // 서울시청 ↔ 부산시청 약 325km
    expect(
      distanceMeters(37.5663, 126.9779, 35.1798, 129.0750),
      closeTo(325000, 3000),
    );
  });

  test('1만 장 계산이 빠르게 끝난다', () {
    final photos = [
      for (var i = 0; i < 10000; i++)
        photo('p$i.jpg', seconds: i * 20, phash: i.isEven ? 0 : bits(4)),
    ];
    final sw = Stopwatch()..start();

    final groups = findSimilarGroups(photos);

    expect(groups, isNotEmpty);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
