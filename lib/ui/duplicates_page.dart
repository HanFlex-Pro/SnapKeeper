import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/duplicates.dart';
import '../data/database.dart';
import '../data/photo_scanner.dart';
import 'library_page.dart';
import 'viewer_page.dart';

PhotoFile toPhotoFile(PhotoRecord r) => PhotoFile(r.path, r.size, r.modified);

/// 확보 용량이 큰 그룹부터. 최상위 함수로 두어 Isolate가 화면 상태를 붙잡지 않게 한다
/// (같은 메서드 안의 클로저는 문맥을 공유해 `this`까지 보내려다 실패한다).
Future<List<DuplicateGroup>> findGroupsInBackground(
  List<PhotoRecord> records,
  Set<String> kept,
) => Isolate.run(
  () =>
      findDuplicates(records, keptSha256: kept)
        ..sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes)),
);

/// 중복 그룹을 보여 주고 지울 사진을 고른다.
/// 완전 동일은 추천 외 사진을 미리 고르고, 거의 동일은 사용자가 직접 고른다.
class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key, required this.db, required this.folder});

  final PhotoDatabase db;
  final String folder;

  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  List<DuplicateGroup>? _groups;
  String? _error;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = widget.db.records(widget.folder);
    final kept = widget.db.keptSha256();
    final List<DuplicateGroup> groups;
    try {
      groups = await findGroupsInBackground(records, kept);
    } catch (e) {
      if (mounted) setState(() => _error = '중복을 계산하지 못했습니다: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _selected
        ..clear()
        ..addAll([
          for (final g in groups)
            if (g.kind == DuplicateKind.exact)
              for (final p in g.photos.skip(1)) p.path,
        ]);
    });
  }

  void _keep(DuplicateGroup group) {
    widget.db.keep({for (final p in group.photos) p.sha256!});
    setState(() {
      _groups!.remove(group);
      _selected.removeAll(group.photos.map((p) => p.path));
    });
  }

  void _toggle(String path) => setState(
    () =>
        _selected.contains(path) ? _selected.remove(path) : _selected.add(path),
  );

  /// 선택한 사진 목록. 같은 사진이 두 그룹에 나오지 않으므로 그대로 합친다.
  List<PhotoRecord> get selectedPhotos => [
    for (final g in _groups ?? const <DuplicateGroup>[])
      for (final p in g.photos)
        if (_selected.contains(p.path)) p,
  ];

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final selected = selectedPhotos;
    final selectedBytes = selected.fold(0, (sum, p) => sum + p.size);
    return Scaffold(
      appBar: AppBar(title: const Text('중복 사진')),
      body: _error != null
          ? Center(child: Text(_error!))
          : groups == null
          ? const Center(child: CircularProgressIndicator())
          : groups.isEmpty
          ? const Center(child: Text('중복 사진이 없습니다.'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_summary(groups)),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: groups.length,
                    itemBuilder: (context, i) => _GroupCard(
                      group: groups[i],
                      selected: _selected,
                      onToggle: _toggle,
                      onKeep: () => _keep(groups[i]),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: groups == null || groups.isEmpty
          ? null
          : BottomAppBar(
              child: Row(
                children: [
                  Text(
                    '선택 ${selected.length}장 · ${formatBytes(selectedBytes)}',
                  ),
                ],
              ),
            ),
    );
  }

  String _summary(List<DuplicateGroup> groups) {
    final exact = groups.where((g) => g.kind == DuplicateKind.exact).length;
    final near = groups.length - exact;
    final bytes = groups.fold(0, (sum, g) => sum + g.reclaimableBytes);
    return '완전 동일 $exact그룹 · 거의 동일 $near그룹 · '
        '추천 사진만 남기면 ${formatBytes(bytes)} 확보';
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.selected,
    required this.onToggle,
    required this.onKeep,
  });

  final DuplicateGroup group;
  final Set<String> selected;
  final void Function(String path) onToggle;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final files = group.photos.map(toPhotoFile).toList();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${group.kind == DuplicateKind.exact ? '완전 동일' : '거의 동일'}'
                    ' · ${group.photos.length}장 · ${group.reason}',
                  ),
                ),
                TextButton(onPressed: onKeep, child: const Text('이 그룹 보관')),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < files.length; i++)
                  _Candidate(
                    photo: files[i],
                    recommended: i == 0,
                    selected: selected.contains(files[i].path),
                    onToggle: () => onToggle(files[i].path),
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ViewerPage(photos: files, initialIndex: i),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Candidate extends StatelessWidget {
  const _Candidate({
    required this.photo,
    required this.recommended,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
  });

  final PhotoFile photo;
  final bool recommended;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 140,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Thumbnail(photo, onTap: onOpen),
                Positioned(
                  top: 0,
                  right: 0,
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => onToggle(),
                    semanticLabel: '${photo.name} 지우기 선택',
                  ),
                ),
                if (recommended)
                  const Positioned(
                    left: 4,
                    bottom: 4,
                    child: Chip(
                      label: Text('남길 사진 추천'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
          Text(photo.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            formatBytes(photo.size),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
