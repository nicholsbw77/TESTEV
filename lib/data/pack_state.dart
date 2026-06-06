import 'dart:math';
import '../decoder/constants.dart';

class PackState {
  // Cell voltages (96 cells, NaN = no data)
  List<double> cells = List.filled(numCells, double.nan);

  // Module temperatures: (T1, T2) per module, degrees C
  List<(double, double)> temps =
      List.generate(numModules, (_) => (double.nan, double.nan));

  // Pack-level from 0x102
  double packVoltage = 0.0;
  double packCurrent = double.nan;
  double negTerminalTempC = double.nan;

  // SOC from 0x302 / 0x332
  double soc = double.nan;
  double socSoe = double.nan;

  // Energy counters
  double kwhCharged = double.nan;
  double kwhDischarged = double.nan;

  // Power limits
  double maxDischargeKw = double.nan;
  double maxRegenKw = double.nan;
  double maxDischargeCurrent = double.nan;
  double maxChargeCurrent = double.nan;
  double wotCurrentLimit = double.nan;

  // Isolation from 0x322
  double isolationKohm = double.nan;

  // Contactor from 0x312
  String contactorState = 'N/A';

  // Identity
  String serialNumber = '';
  double odometerKm = double.nan;

  // Connection metadata
  bool connected = false;
  bool vehicleBus = false;
  int fps = 0;
  String adapterType = '';
  String modeLabel = 'can';

  // ── Computed: cells ───────────────────────────────────────────────────

  List<double> get validCells =>
      cells.where((v) => !v.isNaN && v > 0.5).toList();

  double get cellMin {
    final vc = validCells;
    return vc.isEmpty ? double.nan : vc.reduce(min);
  }

  double get cellMax {
    final vc = validCells;
    return vc.isEmpty ? double.nan : vc.reduce(max);
  }

  double get cellAvg {
    final vc = validCells;
    return vc.isEmpty ? double.nan : vc.reduce((a, b) => a + b) / vc.length;
  }

  double get cellDeltaMv {
    final vc = validCells;
    if (vc.length < 2) return 0.0;
    return (vc.reduce(max) - vc.reduce(min)) * 1000;
  }

  int get minCellIndex {
    final target = cellMin;
    if (target.isNaN) return 0;
    for (int i = 0; i < cells.length; i++) {
      if (!cells[i].isNaN && (cells[i] - target).abs() < 0.00001) return i;
    }
    return 0;
  }

  int get maxCellIndex {
    final target = cellMax;
    if (target.isNaN) return 0;
    for (int i = 0; i < cells.length; i++) {
      if (!cells[i].isNaN && (cells[i] - target).abs() < 0.00001) return i;
    }
    return 0;
  }

  // ── Computed: pack voltage ────────────────────────────────────────────

  double get packVoltageFromCells {
    final vc = validCells;
    if (vc.isEmpty) return 0.0;
    return vc.reduce((a, b) => a + b);
  }

  double get bestPackVoltage {
    final fromCells = packVoltageFromCells;
    final validCount = validCells.length;
    if (fromCells > 50 && validCount >= 90) return fromCells;
    if (packVoltage > 50) return packVoltage;
    if (validCount >= 20) return cellAvg * numCells;
    return fromCells;
  }

  double get kwhTotal {
    final c = kwhCharged.isNaN ? 0.0 : kwhCharged;
    final d = kwhDischarged.isNaN ? 0.0 : kwhDischarged;
    return c + d;
  }

  // ── Computed: per-module ──────────────────────────────────────────────

  double moduleSpreadMv(int mod) {
    final start = mod * cellsPerModule;
    final modCells = cells
        .sublist(start, start + cellsPerModule)
        .where((v) => !v.isNaN && v > 0.5)
        .toList();
    if (modCells.length < 2) return 0.0;
    return (modCells.reduce(max) - modCells.reduce(min)) * 1000;
  }

  double moduleAvg(int mod) {
    final start = mod * cellsPerModule;
    final modCells = cells
        .sublist(start, start + cellsPerModule)
        .where((v) => !v.isNaN && v > 0.5)
        .toList();
    if (modCells.isEmpty) return double.nan;
    return modCells.reduce((a, b) => a + b) / modCells.length;
  }

  double moduleSum(int mod) {
    final start = mod * cellsPerModule;
    final modCells = cells
        .sublist(start, start + cellsPerModule)
        .where((v) => !v.isNaN && v > 0.5)
        .toList();
    if (modCells.isEmpty) return 0.0;
    return modCells.reduce((a, b) => a + b);
  }
}
