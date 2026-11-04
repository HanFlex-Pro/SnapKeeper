import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('snapkeeper/trash');

/// Windows는 휴지통을 쓸 수 없는 위치에서 영구 삭제되지 않는지 확인하기 전까지(v0.5) 끈다.
bool get trashSupported => Platform.isMacOS;

/// OS 휴지통으로 옮긴다. 영구 삭제는 하지 않으며, 옮길 수 없으면 예외를 던지고 파일을 그대로 둔다.
Future<void> moveToTrash(String path) async {
  if (!trashSupported) {
    throw UnsupportedError('이 OS에서는 아직 휴지통 이동을 지원하지 않습니다.');
  }
  try {
    await _channel.invokeMethod<String>('moveToTrash', path);
  } on PlatformException catch (e) {
    throw FileSystemException(e.message ?? '휴지통으로 옮기지 못함', path);
  }
}
