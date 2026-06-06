import 'package:flutter/material.dart';
import '../../data/pack_state.dart';

class ContactorBadge extends StatelessWidget {
  final PackState state;

  const ContactorBadge({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (state.contactorState) {
      case 'CLOSED':
        color = Colors.green;
        break;
      case 'PRECHARGE':
        color = Colors.yellow;
        break;
      case 'FAULT':
        color = Colors.red;
        break;
      default:
        color = Colors.grey;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            const Text('Contactor',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                border: Border.all(color: color),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                state.contactorState,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
