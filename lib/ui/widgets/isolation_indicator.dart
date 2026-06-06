import 'package:flutter/material.dart';
import '../../data/pack_state.dart';
import '../../data/threshold_evaluator.dart';

class IsolationIndicator extends StatelessWidget {
  final PackState state;

  const IsolationIndicator({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final alert = ThresholdEvaluator.isolationAlert(state.isolationKohm);
    final color = ThresholdEvaluator.alertColor(alert);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            const Text('Isolation',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(
              state.isolationKohm.isNaN
                  ? '--'
                  : '${state.isolationKohm.toStringAsFixed(0)} kΩ',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
