import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/session_logger.dart';
import '../../data/providers.dart';

final _loggerProvider = StateProvider<SessionLogger?>((ref) => null);
final _loggingProvider = StateProvider<bool>((ref) => false);

class SessionControlsWidget extends ConsumerWidget {
  const SessionControlsWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logging = ref.watch(_loggingProvider);
    final logger = ref.watch(_loggerProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () async {
                  if (logging) {
                    final path = await logger?.stop();
                    ref.read(_loggingProvider.notifier).state = false;
                    ref.read(_loggerProvider.notifier).state = null;
                    if (path != null && path.isNotEmpty && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Saved: $path')),
                      );
                    }
                  } else {
                    final state = ref.read(packStateProvider);
                    final newLogger = SessionLogger(mode: state.modeLabel);
                    await newLogger.start();
                    ref.read(_loggerProvider.notifier).state = newLogger;
                    ref.read(_loggingProvider.notifier).state = true;
                  }
                },
                icon: Icon(logging ? Icons.stop : Icons.fiber_manual_record),
                label: Text(logging ? 'Stop' : 'Record'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: logging ? Colors.red : null,
                ),
              ),
            ),
            if (logging) ...[
              const SizedBox(width: 8),
              Text('${logger?.rowsWritten ?? 0} rows',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (!logging && logger?.filePath != null) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: () {
                  final path = logger!.filePath!;
                  Share.shareXFiles([XFile(path)]);
                },
                icon: const Icon(Icons.share),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
