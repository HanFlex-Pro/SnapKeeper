import 'package:flutter_test/flutter_test.dart';
import 'package:snapkeeper/main.dart';

void main() {
  testWidgets('앱이 실행되면 앱 이름을 표시한다', (tester) async {
    await tester.pumpWidget(const SnapKeeperApp());

    expect(find.text('SnapKeeper'), findsOneWidget);
  });
}
