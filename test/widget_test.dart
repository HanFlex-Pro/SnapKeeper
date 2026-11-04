import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/data/settings.dart';
import 'package:snapkeeper/main.dart';

void main() {
  late Directory temp;
  late SettingsStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('snapkeeper_test');
    store = SettingsStore(File('${temp.path}/settings.json'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(SnapKeeperApp(store: store));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  testWidgets('저장된 폴더가 없으면 폴더 선택 버튼을 보여 준다', (tester) async {
    await pumpApp(tester);

    expect(find.text('사진 폴더 선택'), findsOneWidget);
  });

  testWidgets('저장된 폴더가 있으면 다시 연다', (tester) async {
    final photos = Directory('${temp.path}/photos')..createSync();
    store.save(Settings(folderPath: photos.path));

    await pumpApp(tester);

    expect(find.text('사진 폴더 선택'), findsNothing);
    expect(find.text('폴더 변경'), findsOneWidget);
  });

  testWidgets('저장된 폴더가 사라졌으면 다시 고르도록 안내한다', (tester) async {
    store.save(Settings(folderPath: '${temp.path}/없는폴더'));

    await pumpApp(tester);

    expect(find.textContaining('폴더를 찾을 수 없습니다'), findsOneWidget);
    expect(find.text('사진 폴더 선택'), findsOneWidget);
  });
}
