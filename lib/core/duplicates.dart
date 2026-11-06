import 'image_features.dart';
import 'thresholds.dart';

/// 중복 판단에 필요한 사진 정보. DB 한 행에 해당한다.
class PhotoRecord {
  const PhotoRecord({
    required this.path,
    required this.size,
    required this.modified,
    this.sha256,
    this.phash,
    this.meanRgb,
    this.grayStd,
    this.saturation,
    this.width,
    this.height,
    this.takenAt,
    this.camera,
    this.sharpness,
    this.latitude,
    this.longitude,
    this.error,
    this.screenshotMarker,
  });

  final String path;
  final int size;
  final DateTime modified;
  final String? sha256;
  final int? phash;
  final int? meanRgb;
  final double? grayStd;
  final double? saturation;
  final int? width;
  final int? height;
  final DateTime? takenAt;

  /// EXIF 제조사·모델. 없으면 카메라로 찍은 사진이 아닐 가능성이 크다.
  final String? camera;
  final double? sharpness;
  final double? latitude;
  final double? longitude;

  /// 분석 중 오류 (디코딩 실패 등).
  final String? error;

  /// 파일에 iPhone·macOS가 남기는 "Screenshot" 표시가 있는지. 분석 전이면 null.
  final bool? screenshotMarker;

  int get pixels => (width ?? 0) * (height ?? 0);
}

enum DuplicateKind { exact, near, similar }

class DuplicateGroup {
  const DuplicateGroup(this.kind, this.photos, this.reason);

  final DuplicateKind kind;

  /// 첫 번째가 남길 사진으로 추천하는 사진 (비슷한 사진은 베스트 컷).
  final List<PhotoRecord> photos;

  /// 사용자에게 보여 줄 탐지 이유.
  final String reason;

  PhotoRecord get recommended => photos.first;

  /// 추천 사진 외 나머지를 지우면 확보되는 용량.
  int get reclaimableBytes => photos.skip(1).fold(0, (sum, p) => sum + p.size);
}

/// 남길 사진 순서: 해상도가 높은 것 → 촬영일(없으면 수정일)이 오래된 것 → 경로가 짧은 것.
int compareKeepPriority(PhotoRecord a, PhotoRecord b) {
  var c = b.pixels.compareTo(a.pixels);
  if (c != 0) return c;
  c = (a.takenAt ?? a.modified).compareTo(b.takenAt ?? b.modified);
  if (c != 0) return c;
  c = a.path.length.compareTo(b.path.length);
  return c != 0 ? c : a.path.compareTo(b.path);
}

/// 완전 동일 그룹과 거의 동일 그룹을 찾는다.
/// [keptSha256]에 있는 사진(사용자가 보관한 사진)은 후보에서 뺀다.
/// 거의 동일은 완전 동일 그룹마다 추천 사진 한 장만 비교해, 같은 사진이 두 번 나오지 않게 한다.
List<DuplicateGroup> findDuplicates(
  List<PhotoRecord> photos, {
  Set<String> keptSha256 = const {},
}) {
  final groups = <DuplicateGroup>[];
  final representatives = <PhotoRecord>[];
  for (final same in groupByContent(photos, keptSha256: keptSha256)) {
    representatives.add(same.first);
    if (same.length > 1) {
      groups.add(DuplicateGroup(DuplicateKind.exact, same, '파일 내용이 완전히 같음'));
    }
  }

  groups.addAll(_nearGroups(representatives));
  return groups;
}

/// 크기와 SHA-256이 같은 사진끼리 묶는다. 묶음마다 [compareKeepPriority] 순으로 정렬해,
/// 첫 사진이 그 내용의 대표가 된다. 해시가 없거나 보관한 사진은 뺀다.
List<List<PhotoRecord>> groupByContent(
  List<PhotoRecord> photos, {
  Set<String> keptSha256 = const {},
}) {
  final byContent = <String, List<PhotoRecord>>{};
  for (final p in photos) {
    if (p.sha256 == null || keptSha256.contains(p.sha256)) continue;
    byContent.putIfAbsent('${p.size}:${p.sha256}', () => []).add(p);
  }
  return [for (final same in byContent.values) same..sort(compareKeepPriority)];
}

List<DuplicateGroup> _nearGroups(List<PhotoRecord> photos) {
  final usable = [
    for (final p in photos)
      if (p.phash != null &&
          p.meanRgb != null &&
          p.saturation != null &&
          (p.grayStd ?? 0) >= flatImageMaxGrayStd &&
          p.pixels > 0)
        p,
  ];

  // 해밍 거리가 d 이하면 (d+1)개 구간 중 적어도 하나는 값이 같다.
  const bands = nearDuplicateMaxHamming + 1;
  const bitsPerBand = (64 + bands - 1) ~/ bands;
  final buckets = <(int, int), List<int>>{};
  for (var i = 0; i < usable.length; i++) {
    final h = usable[i].phash!;
    for (var band = 0; band < bands; band++) {
      final key = (h >>> (band * bitsPerBand)) & ((1 << bitsPerBand) - 1);
      buckets.putIfAbsent((band, key), () => []).add(i);
    }
  }

  final parent = List.generate(usable.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (final members in buckets.values) {
    for (var x = 0; x < members.length; x++) {
      for (var y = x + 1; y < members.length; y++) {
        final a = members[x], b = members[y];
        if (find(a) != find(b) && _isNear(usable[a], usable[b])) {
          parent[find(a)] = find(b);
        }
      }
    }
  }

  final components = <int, List<PhotoRecord>>{};
  for (var i = 0; i < usable.length; i++) {
    components.putIfAbsent(find(i), () => []).add(usable[i]);
  }
  return [
    for (final members in components.values)
      if (members.length > 1) _nearGroup(members),
  ];
}

DuplicateGroup _nearGroup(List<PhotoRecord> members) {
  members.sort(compareKeepPriority);
  final keep = members.first.phash!;
  final distance = members
      .skip(1)
      .map((p) => hammingDistance(keep, p.phash!))
      .reduce((a, b) => a > b ? a : b);
  return DuplicateGroup(
    DuplicateKind.near,
    members,
    '보이는 내용이 거의 같음 (해시 차이 $distance)',
  );
}

bool _isNear(PhotoRecord a, PhotoRecord b) {
  if (hammingDistance(a.phash!, b.phash!) > nearDuplicateMaxHamming) {
    return false;
  }
  final ra = a.width! / a.height!, rb = b.width! / b.height!;
  if ((ra - rb).abs() / (ra > rb ? ra : rb) > nearDuplicateMaxAspectDiff) {
    return false;
  }
  return colorDistance(a.meanRgb!, b.meanRgb!) <= nearDuplicateMaxColorDiff &&
      (a.saturation! - b.saturation!).abs() <= nearDuplicateMaxSaturationDiff;
}
