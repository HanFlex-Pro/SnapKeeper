import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 실제 파일 입출력이 끝나 로딩 표시가 사라질 때까지 기다린다.
/// 고정 시간을 기다리면 느린 CI 러너에서 실패한다.
Future<void> pumpUntilLoaded(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  do {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  } while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
      DateTime.now().isBefore(deadline));
}

/// Windows는 이미지를 읽는 중인 파일을 지울 수 없어 잠시 기다렸다 다시 시도한다.
Future<void> deleteWithRetry(Directory dir) async {
  for (var i = 0; ; i++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (i >= 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
