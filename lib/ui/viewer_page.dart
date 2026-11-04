import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/photo_info.dart';
import '../data/photo_scanner.dart';

/// 사진 한 장을 크게 보여 준다. 좌우 화살표로 이동하고 Esc로 닫는다.
/// 트랙패드·마우스 휠·`+`/`-`로 확대하고 `0`으로 화면에 맞춘다.
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
  final _zoom = TransformationController();
  Size _viewport = Size.zero;

  /// 확대하면 원본 해상도로 다시 읽는다. 화면 크기 디코딩은 확대하면 흐리게 보여 초점을 확인할 수 없다.
  bool _fullResolution = false;

  static const _maxScale = 8.0;

  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < widget.photos.length - 1;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _onZoom() {
    if (!_fullResolution && _zoom.value.getMaxScaleOnAxis() > 1.05) {
      setState(() => _fullResolution = true);
    }
  }

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.photos.length) return;
    setState(() {
      _index = next;
      _fullResolution = false;
      _zoom.value = Matrix4.identity();
    });
  }

  /// 화면 가운데를 기준으로 [factor]배 확대·축소한다. 배율은 1~8배로 제한한다.
  void _zoomBy(double factor) {
    final current = _zoom.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, _maxScale);
    if (target == 1.0) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final f = target / current;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(_zoom.value);
  }

  ImageProvider _provider(PhotoFile photo, int decodeSize) => ResizeImage(
    FileImage(File(photo.path)),
    width: decodeSize,
    height: decodeSize,
    policy: ResizeImagePolicy.fit,
  );

  /// 이전·다음 사진을 미리 디코딩해 넘길 때 빈 화면이 보이지 않게 한다.
  void _prefetchNeighbors(int decodeSize) {
    for (final i in [_index - 1, _index + 1]) {
      if (i < 0 || i >= widget.photos.length) continue;
      precacheImage(
        _provider(widget.photos[i], decodeSize),
        context,
        onError: (_, _) {}, // 표시할 때 다시 시도하고 그때 안내한다.
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    final screen =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    final decodeSize = max(screen.width, screen.height).round();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchNeighbors(decodeSize);
    });
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const CharacterActivator('+'): () => _zoomBy(2),
        const CharacterActivator('='): () => _zoomBy(2),
        const CharacterActivator('-'): () => _zoomBy(0.5),
        const CharacterActivator('0'): () => _zoom.value = Matrix4.identity(),
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _viewport = constraints.biggest;
                    return InteractiveViewer(
                      transformationController: _zoom,
                      maxScale: _maxScale,
                      child: Image(
                        key: ValueKey(photo.path),
                        // ponytail: 원본 전체를 디코딩한다. 1억 화소급 파노라마는 메모리를 수백 MB 쓰므로,
                        // 문제가 되면 보이는 영역만 타일로 읽는 방식으로 바꾼다.
                        image: _fullResolution
                            ? FileImage(File(photo.path))
                            : _provider(photo, decodeSize),
                        fit: BoxFit.contain,
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        // 원본으로 바꾸는 동안 화면 크기 이미지를 그대로 둔다.
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) => const Center(
                          child: Text(
                            '이 사진을 표시할 수 없습니다.',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    );
                  },
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
