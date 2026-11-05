import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/duplicates.dart';
import '../data/database.dart';
import '../platform/trash.dart' as platform;
import 'review_common.dart';
import 'viewer_page.dart';

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
  DuplicatesPage({
    super.key,
    required this.db,
    required this.folder,
    Future<void> Function(String path)? trash,
    bool? canTrash,
  }) : trash = trash ?? platform.moveToTrash,
       canTrash = canTrash ?? platform.trashSupported;

  final PhotoDatabase db;
  final String folder;

  /// 테스트에서 실제 휴지통 대신 쓸 함수.
  final Future<void> Function(String path) trash;
  final bool canTrash;

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

  /// 선택한 사진 목록. 완전 동일 그룹의 추천 사진은 거의 동일 그룹에도 나오므로 경로로 중복을 없앤다.
  List<PhotoRecord> get selectedPhotos => {
    for (final g in _groups ?? const <DuplicateGroup>[])
      for (final p in g.photos)
        if (_selected.contains(p.path)) p.path: p,
  }.values.toList();

  /// 모든 사진이 선택된 그룹 수. 이대로 지우면 그 사진이 하나도 남지 않는다.
  int get fullySelectedGroups => (_groups ?? const <DuplicateGroup>[])
      .where((g) => g.photos.every((p) => _selected.contains(p.path)))
      .length;

  Future<void> _moveToTrash() async {
    final moved = await runTrashFlow(
      context,
      db: widget.db,
      photos: selectedPhotos,
      fullySelectedGroups: fullySelectedGroups,
      trash: widget.trash,
    );
    if (moved && mounted) await _load();
  }

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
                  Expanded(
                    child: Text(
                      '선택 ${selected.length}장 · ${formatBytes(selectedBytes)}',
                    ),
                  ),
                  if (widget.canTrash)
                    FilledButton.icon(
                      onPressed: selected.isEmpty ? null : _moveToTrash,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('휴지통으로 이동'),
                    )
                  else
                    const Text('이 OS에서는 휴지통 이동을 v0.5부터 지원합니다.'),
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
                  CandidateTile(
                    photo: files[i],
                    badge: i == 0 ? '남길 사진 추천' : null,
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
