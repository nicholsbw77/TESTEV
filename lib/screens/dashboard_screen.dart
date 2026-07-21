import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../can/pack_state.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final state = model.state;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text(
              'TESTEV',
              style: TextStyle(
                color: Color(0xFF00E676),
                fontWeight: FontWeight.w900,
                fontSize: 18,
                letterSpacing: 3,
              ),
            ),
            const Spacer(),
            // Connection indicator
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: state.connected
                    ? const Color(0xFF00E676)
                    : const Color(0xFFFF1744),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              state.connected
                  ? '${state.fps} fps • ${state.adapterType}'
                  : 'Disconnected',
              style: TextStyle(
                color: state.connected
                    ? const Color(0xFF78909C)
                    : const Color(0xFFFF1744),
                fontSize: 11,
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              color: const Color(0xFF78909C),
              onPressed: () => model.disconnect(),
            ),
          ],
        ),
        toolbarHeight: 40,
      ),
      body: SafeArea(
        child: isLandscape
            ? _landscapeLayout(state)
            : _portraitLayout(state),
      ),
    );
  }

  Widget _portraitLayout(PackState state) {
    return Column(
      children: [
        // Delta + metrics
        _deltaCard(state),
        _metricsRow(state),
        _kwhRow(state),
        const SizedBox(height: 4),
        // Cell grid fills remaining space
        Expanded(child: _cellGrid(state)),
      ],
    );
  }

  Widget _landscapeLayout(PackState state) {
    return Row(
      children: [
        // Left: delta + metrics
        SizedBox(
          width: 200,
          child: Column(
            children: [
              _deltaCard(state),
              _metricsColumn(state),
            ],
          ),
        ),
        // Right: cell grid
        Expanded(child: _cellGrid(state)),
      ],
    );
  }

  // ── Pack Delta — the hero widget ──────────────────────────────────────

  Widget _deltaCard(PackState state) {
    final deltaMv = state.cellDeltaMv;
    final color = _deltaColor(deltaMv);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Column(
          children: [
            const Text(
              'PACK DELTA',
              style: TextStyle(
                color: Color(0xFF90CAF9),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              deltaMv > 0 ? '${deltaMv.toStringAsFixed(1)}' : '—',
              style: TextStyle(
                color: color,
                fontSize: 42,
                fontWeight: FontWeight.w900,
                fontFamily: 'RobotoMono',
              ),
            ),
            Text(
              'mV',
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            // Color bar
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 8),
            // Min / Avg / Max
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _statCol('MIN',
                    state.cellMin.isNaN
                        ? '—'
                        : '${state.cellMin.toStringAsFixed(4)}V',
                    'M${(state.minCellIndex ~/ 6 + 1).toString().padLeft(2, '0')}'),
                _statCol('AVG',
                    state.cellAvg.isNaN
                        ? '—'
                        : '${state.cellAvg.toStringAsFixed(4)}V',
                    ''),
                _statCol('MAX',
                    state.cellMax.isNaN
                        ? '—'
                        : '${state.cellMax.toStringAsFixed(4)}V',
                    'M${(state.maxCellIndex ~/ 6 + 1).toString().padLeft(2, '0')}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCol(String label, String value, String sub) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(
                color: Color(0xFF78909C), fontSize: 9, letterSpacing: 1)),
        Text(value,
            style: const TextStyle(
                color: Color(0xFFCFD8DC),
                fontSize: 11,
                fontFamily: 'RobotoMono',
                fontWeight: FontWeight.bold)),
        if (sub.isNotEmpty)
          Text(sub,
              style: const TextStyle(
                  color: Color(0xFF546E7A), fontSize: 9)),
      ],
    );
  }

  // ── Metrics row ───────────────────────────────────────────────────────

  Widget _metricsRow(PackState state) {
    final voltage = state.bestPackVoltage;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(child: _metricTile('SoC',
              state.soc.isNaN ? '—' : '${state.soc.toStringAsFixed(1)}%',
              state.soc > 20 ? const Color(0xFF00E676) : const Color(0xFFFF1744))),
          Expanded(child: _metricTile('Pack V',
              voltage > 0 ? '${voltage.toStringAsFixed(1)}V' : '—',
              const Color(0xFFE0E0E0))),
          Expanded(child: _metricTile('Max kW',
              state.maxDischargeKw.isNaN ? '—' : '${state.maxDischargeKw.toStringAsFixed(0)}',
              state.maxDischargeKw > 200
                  ? const Color(0xFF00E676)
                  : const Color(0xFFFF1744))),
          Expanded(child: _metricTile('WOT A',
              state.wotCurrentLimit.isNaN ? '—' : '${state.wotCurrentLimit.toStringAsFixed(0)}',
              const Color(0xFFE0E0E0))),
        ],
      ),
    );
  }

  Widget _kwhRow(PackState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(child: _metricTile('kWh Charged',
              state.kwhCharged.isNaN ? '—' : state.kwhCharged.toStringAsFixed(1),
              const Color(0xFF00E676))),
          Expanded(child: _metricTile('kWh Discharged',
              state.kwhDischarged.isNaN ? '—' : state.kwhDischarged.toStringAsFixed(1),
              const Color(0xFF90CAF9))),
          Expanded(child: _metricTile('kWh Total',
              state.kwhTotal > 0 ? state.kwhTotal.toStringAsFixed(1) : '—',
              const Color(0xFFFFEB3B))),
          Expanded(child: _metricTile('Current kWh',
              state.bestCurrentKwh.isNaN ? '—' : state.bestCurrentKwh.toStringAsFixed(1),
              const Color(0xFF00E5FF))),
        ],
      ),
    );
  }

  Widget _metricsColumn(PackState state) {
    final voltage = state.bestPackVoltage;
    return Expanded(
      child: ListView(
        padding: const EdgeInsets.all(4),
        children: [
          _metricTile('SoC',
              state.soc.isNaN ? '—' : '${state.soc.toStringAsFixed(1)}%',
              const Color(0xFF00E676)),
          _metricTile('Pack V',
              voltage > 0 ? '${voltage.toStringAsFixed(1)}V' : '—',
              const Color(0xFFE0E0E0)),
          _metricTile('Max kW',
              state.maxDischargeKw.isNaN ? '—' : '${state.maxDischargeKw.toStringAsFixed(0)}',
              const Color(0xFF00E676)),
          _metricTile('kWh Charged',
              state.kwhCharged.isNaN ? '—' : state.kwhCharged.toStringAsFixed(1),
              const Color(0xFF00E676)),
          _metricTile('kWh Total',
              state.kwhTotal > 0 ? state.kwhTotal.toStringAsFixed(1) : '—',
              const Color(0xFFFFEB3B)),
          _metricTile('Current kWh',
              state.bestCurrentKwh.isNaN ? '—' : state.bestCurrentKwh.toStringAsFixed(1),
              const Color(0xFF00E5FF)),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String value, Color valueColor) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF78909C), fontSize: 9, letterSpacing: 1)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    color: valueColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'RobotoMono')),
          ],
        ),
      ),
    );
  }

  // ── Cell grid ─────────────────────────────────────────────────────────

  Widget _cellGrid(PackState state) {
    final avg = state.validCells.isNotEmpty ? state.cellAvg : 4.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            // Header row
            _gridHeader(),
            const Divider(height: 1, color: Color(0xFF1E3A5F)),
            // Module rows
            Expanded(
              child: ListView.builder(
                itemCount: 16,
                itemBuilder: (context, mod) =>
                    _moduleRow(state, mod, avg),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gridHeader() {
    const headers = ['Mod', 'C1', 'C2', 'C3', 'C4', 'C5', 'C6', 'Δ', '°F'];
    return Row(
      children: headers.map((h) {
        final flex = h == 'Mod' ? 1 : (h == 'Δ' || h == '°F') ? 1 : 2;
        return Expanded(
          flex: flex,
          child: Text(
            h,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF90CAF9),
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _moduleRow(PackState state, int mod, double avg) {
    final spread = state.moduleSpreadMv(mod);
    final t1 = state.temps[mod].$1;
    final tempF = t1.isNaN ? '—' : '${(t1 * 9 / 5 + 32).toStringAsFixed(0)}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          // Module label
          Expanded(
            flex: 1,
            child: Text(
              'M${(mod + 1).toString().padLeft(2, '0')}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF90CAF9),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // 6 cells
          ...List.generate(6, (ci) {
            final idx = mod * 6 + ci;
            final v = state.cells[idx];
            final valid = !v.isNaN && v > 0.5;
            return Expanded(
              flex: 2,
              child: Container(
                margin: const EdgeInsets.all(1),
                padding: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(
                  color: valid ? _cellColor(v, avg) : const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  valid ? v.toStringAsFixed(3) : '—',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFE0E0E0),
                    fontSize: 9,
                    fontFamily: 'RobotoMono',
                  ),
                ),
              ),
            );
          }),
          // Spread
          Expanded(
            flex: 1,
            child: Text(
              spread > 0 ? spread.toStringAsFixed(1) : '—',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: spread > 10
                    ? const Color(0xFFFF1744)
                    : spread > 5
                        ? const Color(0xFFFFEB3B)
                        : const Color(0xFF00E676),
                fontSize: 9,
                fontFamily: 'RobotoMono',
              ),
            ),
          ),
          // Temperature (°F)
          Expanded(
            flex: 1,
            child: Text(
              tempF,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFCFD8DC),
                fontSize: 9,
                fontFamily: 'RobotoMono',
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Colors ────────────────────────────────────────────────────────────

  Color _deltaColor(double mv) {
    if (mv <= 20) return const Color(0xFF00E676);
    if (mv <= 50) return const Color(0xFFFFEB3B);
    return const Color(0xFFFF1744);
  }

  Color _cellColor(double v, double avg) {
    final dev = (v - avg) * 1000;
    if (dev < -12) return const Color(0xFF7F0000);
    if (dev < -6) return const Color(0xFF7F4000);
    if (dev > 6) return const Color(0xFF0D3B6E);
    return const Color(0xFF1E4D2B);
  }
}
