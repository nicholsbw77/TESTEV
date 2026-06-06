import 'package:flutter/material.dart';
import '../../data/pack_state.dart';
import '../../data/threshold_evaluator.dart';

class SpreadBar extends StatelessWidget {
  final PackState state;

  const SpreadBar({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final deltaMv = state.cellDeltaMv;
    final color = ThresholdEvaluator.spreadColor(deltaMv);
    final barPct = (deltaMv / 100).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Pack Spread',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(
                  '${deltaMv.toStringAsFixed(1)} mV',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: barPct,
                minHeight: 12,
                backgroundColor: Colors.grey.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 2),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('0', style: TextStyle(fontSize: 9, color: Colors.grey)),
                Text('20mV', style: TextStyle(fontSize: 9, color: Colors.green)),
                Text('50mV', style: TextStyle(fontSize: 9, color: Colors.yellow)),
                Text('100mV', style: TextStyle(fontSize: 9, color: Colors.red)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
