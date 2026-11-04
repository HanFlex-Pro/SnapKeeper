import 'dart:convert';
import 'dart:io';

/// 앱 설정. v0.2에서 DB를 도입하면 그쪽으로 옮긴다.
class Settings {
  const Settings({this.folderPath, this.bookmark});

  final String? folderPath;
  final String? bookmark;
}

/// 설정을 JSON 파일 하나에 저장한다.
class SettingsStore {
  SettingsStore(this.file);

  final File file;

  /// 파일이 없거나 깨졌으면 빈 설정을 돌려준다.
  Settings load() {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return Settings(
        folderPath: json['folderPath'] as String?,
        bookmark: json['bookmark'] as String?,
      );
    } catch (_) {
      return const Settings();
    }
  }

  /// 임시 파일에 쓴 뒤 바꿔치기해, 저장 중에 꺼져도 기존 설정이 깨지지 않게 한다.
  void save(Settings settings) {
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'folderPath': settings.folderPath,
        'bookmark': settings.bookmark,
      }),
      flush: true,
    );
    temp.renameSync(file.path);
  }
}
