import 'dart:io';
import 'dart:isolate';

const supportedExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp'};

class PhotoFile {
  const PhotoFile(this.path, this.size, this.modified);

  final String path;
  final int size;
  final DateTime modified;

  String get name =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
}

class ScanResult {
  const ScanResult(this.photos, this.skippedFolders);

  /// 최신 수정 순, 같으면 파일명 순.
  final List<PhotoFile> photos;

  /// 권한 등으로 읽지 못한 폴더 수.
  final int skippedFolders;
}

/// [root] 아래의 지원 형식 사진을 모은다. UI가 멈추지 않도록 Isolate에서 실행한다.
Future<ScanResult> scanPhotos(String root) =>
    Isolate.run(() => scanPhotosSync(root));

/// 심볼릭 링크는 따라가지 않는다(순환, 중복 방지).
/// 이름이 `.`으로 시작하는 파일과 폴더는 건너뛴다(`.Trashes`, `._IMG.jpg` 같은 시스템 파일).
ScanResult scanPhotosSync(String root) {
  final photos = <PhotoFile>[];
  var skipped = 0;
  final pending = [Directory(root)];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      skipped++;
      continue;
    }
    for (final entry in entries) {
      final name = entry.path.substring(
        entry.path.lastIndexOf(Platform.pathSeparator) + 1,
      );
      if (name.startsWith('.')) continue;
      if (entry is Directory) {
        pending.add(entry);
      } else if (entry is File && _isSupported(name)) {
        try {
          final stat = entry.statSync();
          photos.add(PhotoFile(entry.path, stat.size, stat.modified));
        } on FileSystemException {
          // 목록 수집 중에 지워진 파일
        }
      }
    }
  }
  photos.sort((a, b) {
    final byTime = b.modified.compareTo(a.modified);
    return byTime != 0 ? byTime : a.name.compareTo(b.name);
  });
  return ScanResult(photos, skipped);
}

bool _isSupported(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 &&
      supportedExtensions.contains(name.substring(dot).toLowerCase());
}
