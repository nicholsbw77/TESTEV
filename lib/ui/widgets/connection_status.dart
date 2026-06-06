import 'package:flutter/material.dart';
import '../../data/pack_state.dart';

class ConnectionStatusChip extends StatelessWidget {
  final PackState state;

  const ConnectionStatusChip({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: state.connected ? Colors.green : Colors.red,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          state.connected
              ? '${state.adapterType} • ${state.fps} fps'
              : 'Disconnected',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
