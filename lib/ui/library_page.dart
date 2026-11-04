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
    final photos = scan.photos;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            [
              '사진 ${photos.length}장',
              if (scan.skippedFolders > 0) '읽지 못한 폴더 ${scan.skippedFolders}개',
            ].join(' · '),
          ),
        ),
        Expanded(
          child: photos.isEmpty
              ? const Center(child: Text('이 폴더에는 지원하는 사진이 없습니다.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, i) => Thumbnail(photos[i]),
                ),
        ),
      ],
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

/// 격자 한 칸. 화면에 보이는 칸만 만들어지므로 보이는 사진만 디코딩한다.
class Thumbnail extends StatelessWidget {
  const Thumbnail(this.photo, {super.key});

  final PhotoFile photo;

  // ponytail: 매번 원본을 축소 디코딩한다. 스크롤이 느리면 디스크 썸네일 캐시를 추가.
  static const _decodeSize = 320;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: photo.name,
      waitDuration: const Duration(milliseconds: 600),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Image(
          image: ResizeImage(
            FileImage(File(photo.path)),
            width: _decodeSize,
            height: _decodeSize,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => const Center(
            child: Icon(
              Icons.broken_image_outlined,
              semanticLabel: '표시할 수 없는 사진',
            ),
          ),
        ),
      ),
    );
  }
}
