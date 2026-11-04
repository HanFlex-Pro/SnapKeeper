import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/photo_scanner.dart';
import '../data/settings.dart';
import '../platform/folder_access.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.store});

  final SettingsStore store;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String? _folder;
  ScanResult? _scan;
  String? _message;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final settings = widget.store.load();
    final path = settings.folderPath;
    String? folder;
    String? message;
    if (path != null) {
      try {
        final restored = await FolderAccess.restore(path, settings.bookmark);
        if (restored.bookmark != null) {
          widget.store.save(
            Settings(folderPath: restored.path, bookmark: restored.bookmark),
          );
        }
        if (await Directory(restored.path).exists()) {
          folder = restored.path;
        } else {
          message = '폴더를 찾을 수 없습니다. 다시 선택해 주세요.\n$path';
        }
      } catch (_) {
        message = '폴더에 접근할 수 없습니다. 다시 선택해 주세요.\n$path';
      }
    }
    if (!mounted) return;
    setState(() {
      _folder = folder;
      _message = message;
      _loading = false;
    });
    if (folder != null) await _load(folder);
  }

  Future<void> _load(String folder) async {
    setState(() => _scan = null);
    final scan = await scanPhotos(folder);
    if (!mounted || _folder != folder) return;
    setState(() => _scan = scan);
  }

  Future<void> _pick() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    try {
      await FolderAccess.release();
      final bookmark = await FolderAccess.createBookmark(path);
      widget.store.save(Settings(folderPath: path, bookmark: bookmark));
      setState(() {
        _folder = path;
        _message = null;
      });
      await _load(path);
    } catch (_) {
      setState(() => _message = '폴더를 저장하지 못했습니다. 다시 선택해 주세요.');
    }
  }

  Widget _buildLibrary() {
    final scan = _scan;
    if (scan == null) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('사진을 찾는 중'),
        ],
      );
    }
    return Text(
      [
        '사진 ${scan.photos.length}장',
        if (scan.skippedFolders > 0) '읽지 못한 폴더 ${scan.skippedFolders}개',
      ].join('\n'),
      textAlign: TextAlign.center,
    );
  }

  @override
  Widget build(BuildContext context) {
    final folder = _folder;
    return Scaffold(
      appBar: AppBar(
        title: Text(folder ?? 'SnapKeeper'),
        actions: [
          if (folder != null)
            TextButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.folder_open),
              label: const Text('폴더 변경'),
            ),
        ],
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : folder != null
            ? _buildLibrary()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_message != null) ...[
                    Text(_message!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('사진 폴더 선택'),
                  ),
                ],
              ),
      ),
    );
  }
}
