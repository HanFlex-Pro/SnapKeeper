import 'package:flutter/material.dart';

import '../core/duplicates.dart';
import '../data/database.dart';
import '../data/photo_scanner.dart';
import '../data/remover.dart';
import 'library_page.dart';
import 'viewer_page.dart';

// 중복 화면과 품질 정리 화면이 함께 쓰는 검토·휴지통 UI.

PhotoFile toPhotoFile(PhotoRecord r) => PhotoFile(r.path, r.size, r.modified);

/// 확인 창 → 휴지통 이동 → 결과 창. 확인하고 이동을 시도했으면 true, 취소했으면 false.
/// [fullySelectedGroups]가 0보다 크면 확인 창에서 별도 체크를 요구한다.
Future<bool> runTrashFlow(
  BuildContext context, {
  required PhotoDatabase db,
  required List<PhotoRecord> photos,
  required Future<void> Function(String path) trash,
  int fullySelectedGroups = 0,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => ConfirmTrashDialog(
      count: photos.length,
      bytes: photos.fold(0, (sum, p) => sum + p.size),
      fullySelectedGroups: fullySelectedGroups,
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(content: Text('휴지통으로 옮기는 중')),
    ),
  );
  final result = await moveSelectedToTrash(db, photos, trash: trash);
  if (!context.mounted) return true;
  Navigator.of(context).pop();
  await showDialog<void>(
    context: context,
    builder: (_) => TrashResultDialog(result: result),
  );
  return true;
}

/// 후보 사진 한 장: 썸네일, 지우기 선택 체크박스, 선택 사항으로 표시 배지와 탐지 이유.
class CandidateTile extends StatelessWidget {
  const CandidateTile({
    super.key,
    required this.photo,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    this.badge,
    this.caption,
  });

  final PhotoFile photo;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final String? badge;
  final String? caption;

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
                if (badge != null)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Chip(
                      label: Text(badge!),
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
          if (caption != null)
            Text(
              caption!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// 그룹 한 개: 분류·장수·탐지 이유, 그룹 보관, 사진 타일. 첫 사진에 [badge]를 붙인다.
/// [onSelectOthers]가 있으면 "추천 외 모두 선택" 버튼을 보여 준다.
class GroupCard extends StatelessWidget {
  const GroupCard({
    super.key,
    required this.group,
    required this.selected,
    required this.onToggle,
    required this.onKeep,
    this.badge = '남길 사진 추천',
    this.onSelectOthers,
    this.selectOthersLabel = '추천 외 모두 선택',
  });

  final DuplicateGroup group;
  final Set<String> selected;
  final void Function(String path) onToggle;
  final VoidCallback onKeep;
  final String badge;
  final VoidCallback? onSelectOthers;
  final String selectOthersLabel;

  static const _kindTitles = {
    DuplicateKind.exact: '완전 동일',
    DuplicateKind.near: '거의 동일',
    DuplicateKind.similar: '비슷한 사진',
  };

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
                    '${_kindTitles[group.kind]}'
                    ' · ${group.photos.length}장 · ${group.reason}',
                  ),
                ),
                if (onSelectOthers != null)
                  TextButton(
                    onPressed: onSelectOthers,
                    child: Text(selectOthersLabel),
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
                    badge: i == 0 ? badge : null,
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

/// 휴지통으로 옮기기 전 확인. 그룹의 사진을 모두 지우려 하면 별도로 확인받는다.
class ConfirmTrashDialog extends StatefulWidget {
  const ConfirmTrashDialog({
    super.key,
    required this.count,
    required this.bytes,
    required this.fullySelectedGroups,
  });

  final int count;
  final int bytes;
  final int fullySelectedGroups;

  @override
  State<ConfirmTrashDialog> createState() => _ConfirmTrashDialogState();
}

class _ConfirmTrashDialogState extends State<ConfirmTrashDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final risky = widget.fullySelectedGroups > 0;
    return AlertDialog(
      title: Text('사진 ${widget.count}장을 휴지통으로 옮길까요?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${formatBytes(widget.bytes)}를 확보합니다.'),
          const SizedBox(height: 8),
          const Text('영구 삭제하지 않습니다. 휴지통에서 언제든 되돌릴 수 있습니다.'),
          if (risky) ...[
            const SizedBox(height: 16),
            Text(
              '${widget.fullySelectedGroups}개 그룹은 사진을 모두 골랐습니다. '
              '이대로 옮기면 그 사진은 하나도 남지 않습니다.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            CheckboxListTile(
              value: _acknowledged,
              onChanged: (v) => setState(() => _acknowledged = v ?? false),
              title: const Text('그룹의 사진을 모두 옮기는 것을 확인했습니다'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: risky && !_acknowledged
              ? null
              : () => Navigator.of(context).pop(true),
          child: const Text('휴지통으로 이동'),
        ),
      ],
    );
  }
}

class TrashResultDialog extends StatelessWidget {
  const TrashResultDialog({super.key, required this.result});

  final RemovalResult result;

  @override
  Widget build(BuildContext context) {
    final problems = [
      for (final (p, why) in result.skipped) '건너뜀: ${p.path} ($why)',
      for (final (p, why) in result.failed) '실패: ${p.path} ($why)',
    ];
    return AlertDialog(
      title: Text(
        '${result.moved.length}장을 휴지통으로 옮겼습니다 '
        '(${formatBytes(result.freedBytes)} 확보)',
      ),
      content: problems.isEmpty
          ? null
          : SizedBox(
              width: 480,
              height: 200,
              child: ListView(
                children: [
                  const Text('아래 파일은 옮기지 않았고 그대로 있습니다.'),
                  const SizedBox(height: 8),
                  for (final line in problems) SelectableText(line),
                ],
              ),
            ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('확인'),
        ),
      ],
    );
  }
}
