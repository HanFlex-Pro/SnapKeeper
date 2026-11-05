import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/duplicates.dart';
import '../core/similar.dart';
import '../data/database.dart';
import '../platform/trash.dart' as platform;
import 'review_common.dart';
import 'viewer_page.dart';

/// 최근 촬영한 그룹부터. 최상위 함수로 두어 Isolate가 화면 상태를 붙잡지 않게 한다
/// (duplicates_page.dart 참고).
Future<List<DuplicateGroup>> findSimilarInBackground(
  List<PhotoRecord> records,
  Set<String> kept,
) => Isolate.run(() {
  DateTime latest(DuplicateGroup g) =>
      g.photos.map((p) => p.takenAt!).reduce((a, b) => a.isAfter(b) ? a : b);
  return findSimilarGroups(records, keptSha256: kept)
    ..sort((a, b) => latest(b).compareTo(latest(a)));
});

/// 비슷한 사진 그룹을 보여 주고 지울 사진을 고른다.
/// 어느 컷을 남길지는 주관적이라 미리 고르지 않고, "베스트 컷 외 모두 선택"을 제공한다.
class SimilarPage extends StatefulWidget {
  SimilarPage({
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
  State<SimilarPage> createState() => _SimilarPageState();
}

class _SimilarPageState extends State<SimilarPage> {
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
      groups = await findSimilarInBackground(records, kept);
    } catch (e) {
      if (mounted) setState(() => _error = '비슷한 사진을 계산하지 못했습니다: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      final present = {
        for (final g in groups)
          for (final p in g.photos) p.path,
      };
      _selected.retainAll(present);
    });
  }

  void _toggle(String path) => setState(
    () =>
        _selected.contains(path) ? _selected.remove(path) : _selected.add(path),
  );

  void _selectOthers(DuplicateGroup group) => setState(() {
    _selected.remove(group.recommended.path);
    _selected.addAll(group.photos.skip(1).map((p) => p.path));
  });

  void _keep(DuplicateGroup group) {
    widget.db.keep({for (final p in group.photos) p.sha256!});
    setState(() {
      _groups!.remove(group);
      _selected.removeAll(group.photos.map((p) => p.path));
    });
  }

  /// 그룹끼리 사진이 겹치지 않지만, 다른 화면과 같은 방식으로 경로 중복을 없앤다.
  List<PhotoRecord> get selectedPhotos => {
    for (final g in _groups ?? const <DuplicateGroup>[])
      for (final p in g.photos)
        if (_selected.contains(p.path)) p.path: p,
  }.values.toList();

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
    final bytes = selected.fold(0, (sum, p) => sum + p.size);
    final reclaimable = (groups ?? const <DuplicateGroup>[]).fold(
      0,
      (sum, g) => sum + g.reclaimableBytes,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('비슷한 사진')),
      body: _error != null
          ? Center(child: Text(_error!))
          : groups == null
          ? const Center(child: CircularProgressIndicator())
          : groups.isEmpty
          ? const Center(child: Text('비슷한 사진이 없습니다.'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${groups.length}그룹 · 베스트 컷만 남기면 '
                    '${formatBytes(reclaimable)} 확보',
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: groups.length,
                    itemBuilder: (context, i) => GroupCard(
                      group: groups[i],
                      selected: _selected,
                      onToggle: _toggle,
                      onKeep: () => _keep(groups[i]),
                      badge: '베스트 컷 추천',
                      onSelectOthers: () => _selectOthers(groups[i]),
                      selectOthersLabel: '베스트 컷 외 모두 선택',
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
                      '선택 ${selected.length}장 · ${formatBytes(bytes)}',
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
}
