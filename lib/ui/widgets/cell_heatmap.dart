import 'package:flutter/material.dart';
import '../../data/pack_state.dart';
import '../../data/threshold_evaluator.dart';
import '../../decoder/constants.dart';

class CellHeatmap extends StatelessWidget {
  final PackState state;

  const CellHeatmap({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final mean = state.cellAvg;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Cell Voltages',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (!state.cellMin.isNaN)
                  Text(
                    'Min: ${state.cellMin.toStringAsFixed(3)}V  '
                    'Max: ${state.cellMax.toStringAsFixed(3)}V  '
                    'Δ: ${state.cellDeltaMv.toStringAsFixed(1)}mV',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                childAspectRatio: 2.0,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: numCells,
              itemBuilder: (context, idx) {
                final v = state.cells[idx];
                final color = ThresholdEvaluator.cellColor(v, mean);
                final mod = idx ~/ cellsPerModule + 1;
                final cell = idx % cellsPerModule + 1;

                return Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.3),
                    border: Border.all(color: color, width: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'M${mod}B$cell',
                        style: const TextStyle(fontSize: 7, color: Colors.grey),
                      ),
                      Text(
                        v.isNaN ? '--' : v.toStringAsFixed(3),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
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
