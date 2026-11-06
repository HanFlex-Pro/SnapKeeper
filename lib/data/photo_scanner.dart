import 'dart:io';
import 'dart:isolate';

const supportedExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp'};

class PhotoFile {
  const PhotoFile(this.path, this.size, this.modified);

  final String path;
  final int size;
  final DateTime modified;

  String get name => fileName(path);
}

/// 경로의 마지막 부분. Windows는 `\`와 `/`를 모두 구분자로 쓸 수 있다.
String fileName(String path, {bool windows = false}) {
  final i = windows || Platform.isWindows
      ? path.lastIndexOf(RegExp(r'[\\/]'))
      : path.lastIndexOf('/');
  return path.substring(i + 1);
}

class ScanResult {
  const ScanResult(
    this.photos,
    this.skippedFolders, {
    this.unreadableFiles = 0,
  });

  /// 최신 수정 순, 같으면 파일명 순.
  final List<PhotoFile> photos;

  /// 권한 등으로 읽지 못한 폴더 수.
  final int skippedFolders;

  /// 목록에는 있지만 정보를 읽을 수 없는 사진 수.
  /// 예: exFAT 외장 드라이브에서 macOS가 보여 주기만 하고 열지 못하는 한글 이름 파일.
  final int unreadableFiles;
}

/// [root] 아래의 지원 형식 사진을 모은다. UI가 멈추지 않도록 Isolate에서 실행한다.
Future<ScanResult> scanPhotos(String root) =>
    Isolate.run(() => scanPhotosSync(root));

/// 심볼릭 링크는 따라가지 않는다(순환, 중복 방지).
/// 이름이 `.`으로 시작하는 파일과 폴더는 건너뛴다(`.Trashes`, `._IMG.jpg` 같은 시스템 파일).
ScanResult scanPhotosSync(String root) {
  final photos = <PhotoFile>[];
  var skipped = 0, unreadable = 0;
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
      final name = fileName(entry.path);
      if (name.startsWith('.')) continue;
      if (entry is Directory) {
        pending.add(entry);
      } else if (entry is File && _isSupported(name)) {
        // statSync는 실패해도 예외 대신 notFound를 돌려준다. 목록 수집 중에 지워졌거나,
        // 목록에만 보이고 열 수 없는 파일이다.
        final stat = entry.statSync();
        if (stat.type == FileSystemEntityType.notFound) {
          unreadable++;
        } else {
          photos.add(PhotoFile(entry.path, stat.size, stat.modified));
        }
      }
    }
  }
  photos.sort((a, b) {
    final byTime = b.modified.compareTo(a.modified);
    return byTime != 0 ? byTime : a.name.compareTo(b.name);
  });
  return ScanResult(photos, skipped, unreadableFiles: unreadable);
}

/// 촬영일(없으면 수정일) 최신 순, 같으면 파일명 순.
/// 복사한 사진은 수정일이 복사한 날짜라, 분석으로 촬영일을 알게 되면 이 순서로 다시 정렬한다.
List<PhotoFile> sortByCaptureDate(
  List<PhotoFile> photos,
  Map<String, DateTime> takenAt,
) {
  DateTime date(PhotoFile p) => takenAt[p.path] ?? p.modified;
  return [...photos]..sort((a, b) {
    final byDate = date(b).compareTo(date(a));
    return byDate != 0 ? byDate : a.name.compareTo(b.name);
  });
}

bool _isSupported(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 &&
      supportedExtensions.contains(name.substring(dot).toLowerCase());
}
