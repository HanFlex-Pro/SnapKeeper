import 'dart:io';

import '../core/duplicates.dart';
import 'database.dart';

class RemovalResult {
  final moved = <PhotoRecord>[];

  /// 옮기지 않은 사진과 이유. 파일은 그대로 있다.
  final skipped = <(PhotoRecord, String)>[];
  final failed = <(PhotoRecord, String)>[];

  int get freedBytes => moved.fold(0, (sum, p) => sum + p.size);
}

/// 사용자가 고른 사진만 휴지통으로 옮긴다.
///
/// - 옮기기 직전에 크기와 수정 시각을 다시 확인해, 스캔 후 바뀐 파일은 건너뛴다.
/// - 옮기지 못한 파일은 그대로 두고 이유를 기록한다.
/// - 옮긴 파일만 DB에서 지운다.
Future<RemovalResult> moveSelectedToTrash(
  PhotoDatabase db,
  List<PhotoRecord> selected, {
  required Future<void> Function(String path) trash,
}) async {
  final result = RemovalResult();
  for (final photo in selected) {
    final FileStat stat;
    try {
      stat = await File(photo.path).stat();
    } on FileSystemException {
      result.skipped.add((photo, '파일을 확인할 수 없음'));
      continue;
    }
    if (stat.type == FileSystemEntityType.notFound) {
      result.skipped.add((photo, '파일이 이미 없음'));
      continue;
    }
    if (stat.size != photo.size ||
        stat.modified.millisecondsSinceEpoch !=
            photo.modified.millisecondsSinceEpoch) {
      result.skipped.add((photo, '스캔한 뒤 파일이 바뀜'));
      continue;
    }
    try {
      await trash(photo.path);
    } catch (e) {
      result.failed.add((photo, e is FileSystemException ? e.message : '$e'));
      continue;
    }
    db.removePhoto(photo.path);
    result.moved.add(photo);
  }
  return result;
}
