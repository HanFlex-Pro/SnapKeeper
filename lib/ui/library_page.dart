import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/analyzer.dart';
import '../data/database.dart';
import '../data/photo_scanner.dart';
import '../platform/background_activity.dart';
import '../platform/folder_access.dart';
import 'duplicates_page.dart';
import 'viewer_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.db});

  final PhotoDatabase db;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String? _folder;
  ScanResult? _scan;
  String? _message;
  bool _loading = true;

  /// 분석 진행 (끝난 수, 전체 수). 분석 중이 아니면 null.
  (int, int)? _analysis;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _generation++; // 진행 중인 분석을 멈춘다.
    super.dispose();
  }

  Future<void> _restore() async {
    final saved = widget.db.lastFolder();
    final path = saved?.path;
    String? folder;
    String? message;
    if (path != null) {
      try {
        final restored = await FolderAccess.restore(path, saved!.bookmark);
        if (restored.bookmark != null) {
          widget.db.saveFolder(restored.path, restored.bookmark);
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
    final generation = ++_generation;
    setState(() {
      _scan = null;
      _analysis = null;
    });
    final scan = await scanPhotos(folder);
    if (!mounted || generation != _generation) return;
    setState(() => _scan = scan);
    final pending = widget.db.sync(folder, scan.photos);
    if (pending.isNotEmpty) await _analyze(pending, generation);
  }

  Future<void> _analyze(List<String> pending, int generation) async {
    bool stale() => !mounted || generation != _generation;
    setState(() => _analysis = (0, pending.length));
    await BackgroundActivity.begin('사진 분석');
    try {
      await analyzePhotos(
        widget.db,
        pending,
        isCancelled: stale,
        onProgress: (done, total) {
          if (!stale()) setState(() => _analysis = (done, total));
        },
      );
    } finally {
      await BackgroundActivity.end();
    }
    if (!stale()) setState(() => _analysis = null);
  }

  Future<void> _pick() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    try {
      await FolderAccess.release();
      final bookmark = await FolderAccess.createBookmark(path);
      widget.db.saveFolder(path, bookmark);
      setState(() {
        _folder = path;
        _message = null;
      });
      await _load(path);
    } catch (_) {
      setState(() => _message = '폴더를 저장하지 못했습니다. 다시 선택해 주세요.');
    }
  }

  Future<void> _openDuplicates(String folder) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DuplicatesPage(db: widget.db, folder: folder),
      ),
    );
    // 휴지통으로 옮긴 사진을 목록에서 뺀다. 분석 결과는 DB에 있어 다시 분석하지 않는다.
    if (mounted) await _load(folder);
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
    final analysis = _analysis;
    return Column(
      children: [
        if (analysis != null)
          LinearProgressIndicator(
            value: analysis.$2 == 0 ? null : analysis.$1 / analysis.$2,
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            [
              '사진 ${photos.length}장',
              if (scan.skippedFolders > 0) '읽지 못한 폴더 ${scan.skippedFolders}개',
              if (analysis != null) '분석 중 ${analysis.$1} / ${analysis.$2}',
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
                  itemBuilder: (context, i) => Thumbnail(
                    photos[i],
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ViewerPage(photos: photos, initialIndex: i),
                      ),
                    ),
                  ),
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
          if (folder != null && _scan != null)
            TextButton.icon(
              onPressed: _analysis == null
                  ? () => _openDuplicates(folder)
                  : null,
              icon: const Icon(Icons.content_copy),
              label: Text(_analysis == null ? '중복 찾기' : '분석이 끝나면 중복 찾기'),
            ),
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
  const Thumbnail(this.photo, {super.key, this.onTap});

  final PhotoFile photo;
  final VoidCallback? onTap;

  // ponytail: 매번 원본을 축소 디코딩한다. 스크롤이 느리면 디스크 썸네일 캐시를 추가.
  static const _decodeSize = 320;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: photo.name,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        child: Ink(
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
      ),
    );
  }
}
