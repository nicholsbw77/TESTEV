import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/providers.dart';
import '../../data/pack_state.dart';
import '../../decoder/constants.dart';
import '../widgets/cell_heatmap.dart';
import '../widgets/pack_gauge.dart';
import '../widgets/temp_map.dart';
import '../widgets/spread_bar.dart';
import '../widgets/contactor_badge.dart';
import '../widgets/isolation_indicator.dart';
import '../widgets/connection_status.dart';
import '../widgets/session_controls.dart';
import 'cell_detail_screen.dart';
import 'settings_screen.dart';
import 'session_log_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  Timer? _refreshTimer;

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
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        title: const Text('TESTEV'),
        actions: [
          ConnectionStatusChip(state: state),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'cells':
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const CellDetailScreen()));
                  break;
                case 'logs':
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const SessionLogScreen()));
                  break;
                case 'settings':
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const SettingsScreen()));
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'cells', child: Text('Cell Detail')),
              PopupMenuItem(value: 'logs', child: Text('Session Logs')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: isLandscape
          ? _buildLandscape(state)
          : _buildPortrait(state),
    );
  }

  Widget _buildPortrait(PackState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          _buildGaugeRow(state),
          const SizedBox(height: 8),
          CellHeatmap(state: state),
          const SizedBox(height: 8),
          TempMap(state: state),
          const SizedBox(height: 8),
          SpreadBar(state: state),
          const SizedBox(height: 8),
          _buildInfoRow(state),
          const SizedBox(height: 8),
          SessionControlsWidget(),
        ],
      ),
    );
  }

  Widget _buildLandscape(PackState state) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                CellHeatmap(state: state),
                const SizedBox(height: 8),
                TempMap(state: state),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                _buildGaugeRow(state),
                const SizedBox(height: 8),
                SpreadBar(state: state),
                const SizedBox(height: 8),
                _buildInfoRow(state),
                const SizedBox(height: 8),
                SessionControlsWidget(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGaugeRow(PackState state) {
    return Row(
      children: [
        Expanded(
          child: PackGauge(
            label: 'Pack V',
            value: state.bestPackVoltage,
            unit: 'V',
            min: 280,
            max: 405,
          ),
        ),
        Expanded(
          child: PackGauge(
            label: 'SoC',
            value: state.soc,
            unit: '%',
            min: 0,
            max: 100,
          ),
        ),
        Expanded(
          child: PackGauge(
            label: 'Current',
            value: state.packCurrent,
            unit: 'A',
            min: -200,
            max: 200,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(PackState state) {
    return Row(
      children: [
        Expanded(child: ContactorBadge(state: state)),
        Expanded(child: IsolationIndicator(state: state)),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  const Text('Max kW',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                  Text(
                    state.maxDischargeKw.isNaN
                        ? '--'
                        : state.maxDischargeKw.toStringAsFixed(0),
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  const Text('WOT A',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                  Text(
                    state.wotCurrentLimit.isNaN
                        ? '--'
                        : state.wotCurrentLimit.toStringAsFixed(0),
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
