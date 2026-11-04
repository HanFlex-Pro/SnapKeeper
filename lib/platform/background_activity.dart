import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('snapkeeper/activity');

/// 긴 분석 중에 macOS App Nap을 막는다. 막지 않으면 창이 가려졌을 때 분석이 크게 느려진다(M0).
/// 다른 OS에서는 아무것도 하지 않는다.
class BackgroundActivity {
  const BackgroundActivity._();

  static Future<void> begin(String reason) => _call('begin', reason);

  static Future<void> end() => _call('end');

  /// 실패해도 분석은 계속한다. 느려질 뿐 결과는 같다.
  static Future<void> _call(String method, [String? argument]) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on MissingPluginException {
      // 테스트 환경
    } on PlatformException {
      // 무시
    }
  }
}
