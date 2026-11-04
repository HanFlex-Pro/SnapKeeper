import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/database.dart';
import 'ui/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final db =
      PhotoDatabase.open('${dir.path}${Platform.pathSeparator}snapkeeper.db')
        ..importLegacySettings(
          File('${dir.path}${Platform.pathSeparator}settings.json'),
        );
  runApp(SnapKeeperApp(db: db));
}

class SnapKeeperApp extends StatelessWidget {
  const SnapKeeperApp({super.key, required this.db});

  final PhotoDatabase db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapKeeper',
      home: LibraryPage(db: db),
    );
  }
}
