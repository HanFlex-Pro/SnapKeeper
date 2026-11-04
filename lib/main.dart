import 'package:flutter/material.dart';

void main() {
  runApp(const SnapKeeperApp());
}

class SnapKeeperApp extends StatelessWidget {
  const SnapKeeperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'SnapKeeper',
      home: Scaffold(body: Center(child: Text('SnapKeeper'))),
    );
  }
}
