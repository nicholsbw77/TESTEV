import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SessionLogScreen extends StatefulWidget {
  const SessionLogScreen({super.key});

  @override
  State<SessionLogScreen> createState() => _SessionLogScreenState();
}

class _SessionLogScreenState extends State<SessionLogScreen> {
  List<FileSystemEntity> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${dir.path}/logs');
    if (!logDir.existsSync()) {
      setState(() => _sessions = []);
      return;
    }

    final files = logDir
        .listSync()
        .where((f) => f.path.endsWith('_session.csv'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    setState(() => _sessions = files);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session Logs')),
      body: _sessions.isEmpty
          ? const Center(child: Text('No sessions recorded yet'))
          : ListView.builder(
              itemCount: _sessions.length,
              itemBuilder: (context, i) {
                final file = _sessions[i];
                final name = file.path.split('/').last;
                final stat = file.statSync();

                return ListTile(
                  leading: const Icon(Icons.description),
                  title: Text(name, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '${(stat.size / 1024).toStringAsFixed(1)} KB',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.share),
                    onPressed: () {
                      Share.shareXFiles([XFile(file.path)]);
                    },
                  ),
                );
              },
            ),
    );
  }
}
