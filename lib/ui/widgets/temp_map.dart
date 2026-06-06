import 'package:flutter/material.dart';
import '../../data/pack_state.dart';
import '../../data/threshold_evaluator.dart';
import '../../decoder/constants.dart';

class TempMap extends StatelessWidget {
  final PackState state;

  const TempMap({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Module Temperatures',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                childAspectRatio: 1.2,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: numModules * 2,
              itemBuilder: (context, idx) {
                final mod = idx ~/ 2;
                final sensor = idx % 2;
                final temp = sensor == 0
                    ? state.temps[mod].$1
                    : state.temps[mod].$2;
                final alert = ThresholdEvaluator.tempAlert(temp);
                final color = ThresholdEvaluator.alertColor(alert);

                return Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    border: Border.all(color: color, width: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'M${mod + 1}T${sensor + 1}',
                        style: const TextStyle(fontSize: 7, color: Colors.grey),
                      ),
                      Text(
                        temp.isNaN ? '--' : '${temp.toStringAsFixed(1)}°',
                        style: TextStyle(fontSize: 10, color: color),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
