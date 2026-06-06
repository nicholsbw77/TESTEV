import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/providers.dart';
import '../../data/pack_state.dart';
import '../../data/threshold_evaluator.dart';
import '../../decoder/constants.dart';

class CellDetailScreen extends ConsumerStatefulWidget {
  const CellDetailScreen({super.key});

  @override
  ConsumerState<CellDetailScreen> createState() => _CellDetailScreenState();
}

class _CellDetailScreenState extends ConsumerState<CellDetailScreen> {
  Timer? _refreshTimer;
  int _expandedModule = -1;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(
      Duration(milliseconds: 1000 ~/ guiRefreshHz),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(packStateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cell Detail')),
      body: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: numModules,
        itemBuilder: (context, mod) => _buildModule(state, mod),
      ),
    );
  }

  Widget _buildModule(PackState state, int mod) {
    final mean = state.cellAvg;
    final spread = state.moduleSpreadMv(mod);
    final modAvg = state.moduleAvg(mod);
    final t1 = state.temps[mod].$1;
    final t2 = state.temps[mod].$2;
    final expanded = _expandedModule == mod;
    final spreadAlert = ThresholdEvaluator.moduleSpreadAlert(spread);

    return Card(
      child: InkWell(
        onTap: () => setState(() {
          _expandedModule = expanded ? -1 : mod;
        }),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              // Module header
              Row(
                children: [
                  Text(
                    'M${(mod + 1).toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  // Cell voltage chips
                  ...List.generate(cellsPerModule, (i) {
                    final idx = mod * cellsPerModule + i;
                    final v = state.cells[idx];
                    final color = ThresholdEvaluator.cellColor(v, mean);
                    return Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          v.isNaN ? '--' : v.toStringAsFixed(3),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 10, color: color),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(width: 8),
                  // Spread indicator
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: ThresholdEvaluator.alertColor(spreadAlert)
                          .withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      '${spread.toStringAsFixed(1)}mV',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                  ),
                ],
              ),

              // Expanded detail
              if (expanded) ...[
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _infoChip('Avg', modAvg.isNaN ? '--' : '${modAvg.toStringAsFixed(3)}V'),
                    _infoChip('Sum', '${state.moduleSum(mod).toStringAsFixed(2)}V'),
                    _infoChip('Spread', '${spread.toStringAsFixed(1)}mV'),
                    _infoChip('T1', t1.isNaN ? '--' : '${t1.toStringAsFixed(1)}°C'),
                    _infoChip('T2', t2.isNaN ? '--' : '${t2.toStringAsFixed(1)}°C'),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
