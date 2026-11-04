import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/photo_info.dart';
import '../data/photo_scanner.dart';

/// 사진 한 장을 크게 보여 준다. 좌우 화살표로 이동하고 Esc로 닫는다.
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  final List<PhotoFile> photos;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late int _index = widget.initialIndex;

  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < widget.photos.length - 1;

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.photos.length) return;
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    final screen =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    final decodeSize = max(screen.width, screen.height).round();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(
              '${photo.name}  ·  ${_index + 1} / ${widget.photos.length}',
            ),
          ),
          body: Row(
            children: [
              IconButton(
                onPressed: _hasPrevious ? () => _move(-1) : null,
                icon: const Icon(Icons.chevron_left),
                color: Colors.white,
                tooltip: '이전 사진',
              ),
              Expanded(
                child: Image(
                  key: ValueKey(photo.path),
                  image: ResizeImage(
                    FileImage(File(photo.path)),
                    width: decodeSize,
                    height: decodeSize,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) => const Center(
                    child: Text(
                      '이 사진을 표시할 수 없습니다.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: _hasNext ? () => _move(1) : null,
                icon: const Icon(Icons.chevron_right),
                color: Colors.white,
                tooltip: '다음 사진',
              ),
              InfoPanel(key: ValueKey('info ${photo.path}'), photo: photo),
            ],
          ),
        ),
      ),
    );
  }
}

/// 사진 정보. 읽을 수 없는 항목은 표시하지 않는다.
class InfoPanel extends StatefulWidget {
  const InfoPanel({super.key, required this.photo});

  final PhotoFile photo;

  @override
  State<InfoPanel> createState() => _InfoPanelState();
}

class _InfoPanelState extends State<InfoPanel> {
  late final Future<PhotoInfo> _info = readPhotoInfo(widget.photo.path);

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    return Container(
      width: 280,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: FutureBuilder<PhotoInfo>(
        future: _info,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final rows = <(String, String)>[
            ('파일명', photo.name),
            ('경로', photo.path),
            ('크기', formatBytes(photo.size)),
            if (info?.width != null) ('해상도', '${info!.width} × ${info.height}'),
            if (info?.takenAt != null) ('촬영일', formatDate(info!.takenAt!)),
            if (info?.camera != null) ('카메라', info!.camera!),
            ('수정일', formatDate(photo.modified)),
          ];
          return ListView(
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      SelectableText(value),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}
