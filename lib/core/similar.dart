import 'dart:math';

import 'duplicates.dart';
import 'image_features.dart';
import 'thresholds.dart';

/// 촬영 시각·구도·위치가 가까운 사진을 묶는다. 그룹 첫 사진은 베스트 컷이다.
///
/// 촬영 시각순으로 훑으며 **그룹의 첫 사진**과 비교한다. 바로 앞 사진과 비교하면
/// 조금씩 다른 사진이 끝없이 이어 붙기 때문이다.
/// 완전 동일 사진은 대표 한 장만 쓰고, 촬영일·해시·크기가 없거나 분석에 실패했거나
/// 보관한 사진은 뺀다.
List<DuplicateGroup> findSimilarGroups(
  List<PhotoRecord> photos, {
  Set<String> keptSha256 = const {},
}) {
  final candidates = [
    for (final same in groupByContent(photos, keptSha256: keptSha256))
      if (_usable(same.first)) same.first,
  ]..sort((a, b) => a.takenAt!.compareTo(b.takenAt!));

  final groups = <DuplicateGroup>[];
  var current = <PhotoRecord>[];
  void close() {
    if (current.length > 1) groups.add(_group(current));
  }

  for (final p in candidates) {
    if (current.isNotEmpty && _belongs(current.first, p)) {
      current.add(p);
    } else {
      close();
      current = [p];
    }
  }
  close();
  return groups;
}

bool _usable(PhotoRecord p) =>
    p.takenAt != null && p.phash != null && p.pixels > 0 && p.error == null;

bool _belongs(PhotoRecord first, PhotoRecord p) {
  if (p.takenAt!.difference(first.takenAt!).inSeconds > similarMaxSeconds) {
    return false;
  }
  if (hammingDistance(first.phash!, p.phash!) > similarMaxHamming) return false;
  final (lat1, lon1, lat2, lon2) = (
    first.latitude,
    first.longitude,
    p.latitude,
    p.longitude,
  );
  if (lat1 != null && lon1 != null && lat2 != null && lon2 != null) {
    return distanceMeters(lat1, lon1, lat2, lon2) <= similarMaxMeters;
  }
  return true;
}

/// 베스트 컷: 선명도가 높은 사진 → 해상도가 높은 사진 → 경로순.
int compareBestShot(PhotoRecord a, PhotoRecord b) {
  var c = (b.sharpness ?? 0).compareTo(a.sharpness ?? 0);
  if (c != 0) return c;
  c = b.pixels.compareTo(a.pixels);
  return c != 0 ? c : a.path.compareTo(b.path);
}

DuplicateGroup _group(List<PhotoRecord> byTime) {
  final seconds = byTime.last.takenAt!
      .difference(byTime.first.takenAt!)
      .inSeconds;
  final first = byTime.first.phash!;
  final maxHamming = byTime
      .skip(1)
      .map((p) => hammingDistance(first, p.phash!))
      .reduce(max);
  return DuplicateGroup(
    DuplicateKind.similar,
    [...byTime]..sort(compareBestShot),
    '$seconds초 간격, 구도 유사 (해시 차이 최대 $maxHamming)',
  );
}

/// 두 위경도 사이 거리(m). 하버사인 공식.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a =
      pow(sin(dLat / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}
