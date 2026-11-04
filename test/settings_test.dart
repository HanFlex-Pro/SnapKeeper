import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/settings.dart';

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('snapkeeper_settings');
    file = File('${temp.path}/sub/settings.json');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('저장한 설정을 다시 읽는다', () {
    final store = SettingsStore(file);
    store.save(const Settings(folderPath: '/사진', bookmark: 'abc'));

    final loaded = SettingsStore(file).load();

    expect(loaded.folderPath, '/사진');
    expect(loaded.bookmark, 'abc');
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('파일이 없으면 빈 설정', () {
    expect(SettingsStore(file).load().folderPath, isNull);
  });

  test('파일이 깨졌으면 빈 설정', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{깨진');

    expect(SettingsStore(file).load().folderPath, isNull);
  });
}
