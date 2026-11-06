import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/duplicates.dart';
import '../core/quality.dart';
import '../data/database.dart';
import '../platform/trash.dart' as platform;
import 'review_common.dart';
import 'viewer_page.dart';

/// 최상위 함수로 두어 Isolate가 화면 상태를 붙잡지 않게 한다 (duplicates_page.dart 참고).
Future<Map<QualityIssue, List<QualityCandidate>>> findQualityInBackground(
  List<PhotoRecord> records,
  Set<String> kept,
) => Isolate.run(() => findQualityIssues(records, keptSha256: kept));

const _tabTitles = {
  QualityIssue.screenshot: '캡처',
  QualityIssue.lowResolution: '저화질',
  QualityIssue.blurry: '흐림·실수',
};

/// 캡처·저화질·초점 불량 후보를 탭별로 보여 주고 지울 사진을 고른다.
/// 품질은 주관적이라 미리 고르지 않는다.
class QualityPage extends StatefulWidget {
  QualityPage({
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
  State<QualityPage> createState() => _QualityPageState();
}

class _QualityPageState extends State<QualityPage> {
  Map<QualityIssue, List<QualityCandidate>>? _issues;
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
    final Map<QualityIssue, List<QualityCandidate>> issues;
    try {
      issues = await findQualityInBackground(records, kept);
    } catch (e) {
      if (mounted) setState(() => _error = '후보를 계산하지 못했습니다: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _issues = issues;
      // 사라진 사진의 선택은 지운다.
      final present = {
        for (final list in issues.values)
          for (final c in list) c.photo.path,
      };
      _selected.retainAll(present);
    });
  }

  /// 여러 탭에 나오는 사진은 경로로 중복을 없앤다.
  List<PhotoRecord> get selectedPhotos => {
    for (final list in (_issues ?? const {}).values)
      for (final c in list)
        if (_selected.contains(c.photo.path)) c.photo.path: c.photo,
  }.values.toList();

  void _toggle(String path) => setState(
    () =>
        _selected.contains(path) ? _selected.remove(path) : _selected.add(path),
  );

  void _selectAll(List<QualityCandidate> list, bool select) => setState(() {
    final paths = list.map((c) => c.photo.path);
    select ? _selected.addAll(paths) : _selected.removeAll(paths);
  });

  Future<void> _keepSelected() async {
    widget.db.keep({for (final p in selectedPhotos) p.sha256!});
    _selected.clear();
    await _load();
  }

  Future<void> _moveToTrash() async {
    final moved = await runTrashFlow(
      context,
      db: widget.db,
      photos: selectedPhotos,
      trash: widget.trash,
    );
    if (moved && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final issues = _issues;
    final selected = selectedPhotos;
    final bytes = selected.fold(0, (sum, p) => sum + p.size);
    return DefaultTabController(
      length: QualityIssue.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('품질 정리'),
          bottom: issues == null
              ? null
              : TabBar(
                  tabs: [
                    for (final issue in QualityIssue.values)
                      Tab(
                        text: '${_tabTitles[issue]} ${issues[issue]!.length}장',
                      ),
                  ],
                ),
        ),
        body: _error != null
            ? Center(child: Text(_error!))
            : issues == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  for (final issue in QualityIssue.values)
                    _CandidateList(
                      note: issue == QualityIssue.blurry
                          ? '흐리거나 실수로 찍힌 사진 후보입니다. 하늘·안개처럼 원래 세부가 적은 사진이나 '
                                '일부러 흐리게 찍은 사진도 섞일 수 있어, 하나씩 확인한 뒤 고르세요.'
                          : null,
                      candidates: issues[issue]!,
                      selected: _selected,
                      onToggle: _toggle,
                      onSelectAll: (select) =>
                          _selectAll(issues[issue]!, select),
                    ),
                ],
              ),
        bottomNavigationBar: issues == null
            ? null
            : BottomAppBar(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '선택 ${selected.length}장 · ${formatBytes(bytes)}',
                      ),
                    ),
                    TextButton(
                      onPressed: selected.isEmpty ? null : _keepSelected,
                      child: const Text('보관'),
                    ),
                    const SizedBox(width: 8),
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
      ),
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({
    this.note,
    required this.candidates,
    required this.selected,
    required this.onToggle,
    required this.onSelectAll,
  });

  final String? note;
  final List<QualityCandidate> candidates;
  final Set<String> selected;
  final void Function(String path) onToggle;
  final void Function(bool select) onSelectAll;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) {
      return const Center(child: Text('후보가 없습니다.'));
    }
    final files = [for (final c in candidates) toPhotoFile(c.photo)];
    final allSelected = candidates.every(
      (c) => selected.contains(c.photo.path),
    );
    return Column(
      children: [
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text(note!, style: Theme.of(context).textTheme.bodySmall),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => onSelectAll(!allSelected),
            child: Text(allSelected ? '선택 해제' : '전체 선택'),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              mainAxisExtent: 220,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: candidates.length,
            itemBuilder: (context, i) => CandidateTile(
              photo: files[i],
              caption: candidates[i].reason,
              selected: selected.contains(files[i].path),
              onToggle: () => onToggle(files[i].path),
              onOpen: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ViewerPage(photos: files, initialIndex: i),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
