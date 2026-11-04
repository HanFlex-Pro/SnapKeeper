import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('snapkeeper/folder_access');

/// 사용자가 고른 폴더에 다시 접근하기 위한 기능.
/// macOS는 샌드박스 보안 북마크를 쓰고, 다른 OS는 경로를 그대로 쓴다.
class FolderAccess {
  const FolderAccess._();

  /// 방금 고른 폴더의 북마크를 만든다. macOS가 아니면 null.
  static Future<String?> createBookmark(String path) async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('create', path);
  }

  /// 저장된 북마크로 접근을 되찾는다.
  /// 북마크가 오래되어 새로 만들었으면 [bookmark]에 새 값을 돌려준다.
  static Future<({String path, String? bookmark})> restore(
    String path,
    String? bookmark,
  ) async {
    if (!Platform.isMacOS || bookmark == null) {
      return (path: path, bookmark: null);
    }
    final result = await _channel.invokeMapMethod<String, String?>(
      'resolve',
      bookmark,
    );
    return (path: result!['path']!, bookmark: result['bookmark']);
  }

  /// 이전에 되찾은 폴더 접근을 해제한다.
  static Future<void> release() async {
    if (Platform.isMacOS) await _channel.invokeMethod<void>('release');
  }
}
