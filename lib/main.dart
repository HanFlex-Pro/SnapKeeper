import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/settings.dart';
import 'ui/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  runApp(
    SnapKeeperApp(store: SettingsStore(File('${dir.path}/settings.json'))),
  );
}

class SnapKeeperApp extends StatelessWidget {
  const SnapKeeperApp({super.key, required this.store});

  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapKeeper',
      home: LibraryPage(store: store),
    );
  }
}
