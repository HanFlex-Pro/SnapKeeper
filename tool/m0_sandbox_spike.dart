// M0 기술 검증용 임시 화면. 결과를 문서에 기록한 뒤 삭제한다.
// 실행: flutter run -d macos -t tool/m0_sandbox_spike.dart
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _trash = MethodChannel('snapkeeper/trash');
const _bookmark = MethodChannel('snapkeeper/bookmark');
final _home = Platform.environment['HOME']!;
final _state = File('$_home/m0_spike_state.json');
final _log = File('$_home/m0_spike_result.txt');

void main() => runApp(const MaterialApp(home: SpikePage()));

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final _lines = <String>[];

  void _add(String line) {
    _log.writeAsStringSync('$line\n', mode: FileMode.append);
    setState(() => _lines.add(line));
  }

  String _list(String path) {
    try {
      return '성공 ${Directory(path).listSync().length}개';
    } catch (e) {
      return '실패 ${e.runtimeType}';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStart());
  }

  Future<void> _onStart() async {
    _add('--- 앱 시작 ${DateTime.now()}');
    if (!_state.existsSync()) {
      _add('저장된 폴더 없음. 폴더를 선택하세요.');
      return;
    }
    final saved = jsonDecode(_state.readAsStringSync()) as Map<String, dynamic>;
    final path = saved['path'] as String;
    _add('재실행, 북마크 없이 목록 읽기: ${_list(path)}');
    try {
      final resolved = await _bookmark.invokeMethod<String>(
        'resolve',
        saved['bookmark'],
      );
      _add('재실행, 북마크로 목록 읽기: ${_list(resolved!)}');
      await _trashTest(resolved, '재실행');
    } on PlatformException catch (e) {
      _add('북마크 복원 실패: ${e.message}');
    }
  }

  Future<void> _trashTest(String folder, String label) async {
    final file = File('$folder/snapkeeper_spike_$label.txt');
    try {
      file.writeAsStringSync('snapkeeper');
      final to = await _trash.invokeMethod<String>('moveToTrash', file.path);
      _add('$label 휴지통 이동: 원본 사라짐=${!file.existsSync()}, 위치=$to');
    } catch (e) {
      _add('$label 휴지통 이동 실패: $e');
    }
  }

  Future<void> _pick() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    _add('폴더 선택 직후 목록 읽기: ${_list(path)}');
    await _trashTest(path, '선택직후');
    try {
      final bookmark = await _bookmark.invokeMethod<String>('create', path);
      _state.writeAsStringSync(
        jsonEncode({'path': path, 'bookmark': bookmark}),
      );
      _add('북마크 저장 완료. 앱을 완전히 종료한 뒤 다시 실행하세요.');
    } on PlatformException catch (e) {
      _add('북마크 생성 실패: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ElevatedButton(onPressed: _pick, child: const Text('폴더 선택')),
          const SizedBox(height: 12),
          Expanded(child: SelectableText(_lines.join('\n'))),
        ],
      ),
    ),
  );
}
