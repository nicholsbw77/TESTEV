import 'dart:math';

/// Complete pack state — all decoded BMS data in one place.
/// Updated by CAN decoders, consumed by UI widgets.
class PackState {
  // Cell voltages (96 cells, NaN = no data)
  List<double> cells = List.filled(96, double.nan);

  // Module temperatures: (T1, T2) per module, °C
  List<(double, double)> temps =
      List.generate(16, (_) => (double.nan, double.nan));

  // Pack-level data
  double soc = double.nan;         // %
  double socSoe = double.nan;      // % state of energy
  double packVoltage = 0.0;        // V
  double packCurrent = double.nan; // A
  double isolationKohm = double.nan;

  // Power limits
  double maxDischargeKw = double.nan;
  double maxRegenKw = double.nan;
  double maxDischargeCurrent = double.nan;  // A from 0x202
  double maxChargeCurrent = double.nan;     // A from 0x202
  double wotCurrentLimit = double.nan;      // A from 0x7E2

  // Energy counters
  double kwhCharged = double.nan;
  double kwhDischarged = double.nan;

  // Identity
  String serialNumber = '';
  double odometerKm = double.nan;
  String contactorState = 'N/A';

  // Connection
  bool connected = false;
  bool vehicleBus = false;
  int fps = 0;
  String adapterType = '';

  // Sweep buffer for 0x6F2
  final Set<int> _muxSeen = {};
  final List<double> _sweepCells = List.filled(96, double.nan);
  final List<double> _sweepTemps = List.filled(32, double.nan);
  List<double> _goodCells = List.filled(96, double.nan);

  // ── Computed properties ──────────────────────────────────────────────

  /// Pack voltage computed from summing all valid cell voltages
  double get packVoltageFromCells {
    final vc = validCells;
    if (vc.isEmpty) return 0.0;
    return vc.reduce((a, b) => a + b);
  }

  /// Best available pack voltage — prefer cell sum when complete, fall back to CAN
  double get bestPackVoltage {
    final fromCells = packVoltageFromCells;
    final validCount = validCells.length;
    if (fromCells > 50 && validCount >= 90) return fromCells;
    if (packVoltage > 50) return packVoltage;
    return fromCells;
  }

  /// Total kWh throughput (charged + discharged)
  double get kwhTotal {
    final c = kwhCharged.isNaN ? 0.0 : kwhCharged;
    final d = kwhDischarged.isNaN ? 0.0 : kwhDischarged;
    return c + d;
  }

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

  /// Per-module spread in mV
  double moduleSpreadMv(int mod) {
    final start = mod * 6;
    final modCells =
        cells.sublist(start, start + 6).where((v) => !v.isNaN && v > 0.5).toList();
    if (modCells.length < 2) return 0.0;
    return (modCells.reduce(max) - modCells.reduce(min)) * 1000;
  }

  /// Module average voltage
  double moduleAvg(int mod) {
    final start = mod * 6;
    final modCells =
        cells.sublist(start, start + 6).where((v) => !v.isNaN && v > 0.5).toList();
    if (modCells.isEmpty) return double.nan;
    return modCells.reduce((a, b) => a + b) / modCells.length;
  }

  // ── Feed 0x6F2 cell/temp frame ───────────────────────────────────────

  bool feed6F2(List<int> data) {
    if (data.length < 8) return false;
    final mux = data[0];
    if (mux > 0x1F) return false;

    // Extract 56-bit payload little-endian
    int raw = 0;
    for (int i = 7; i >= 1; i--) {
      raw = (raw << 8) | data[i];
    }

    final values = List.generate(4, (i) => (raw >> (i * 14)) & 0x3FFF);

    if (mux <= 0x17) {
      final base = mux * 4;
      for (int i = 0; i < 4; i++) {
        final idx = base + i;
        if (idx < 96) {
          final voltage = values[i] * 0.000305;
          _sweepCells[idx] = voltage;
          // Incremental update: write directly to cells as each frame arrives
          // so slow connections (OBDLink) show data without needing a full sweep
          if (voltage > 0.5 && voltage < 5.0) {
            cells[idx] = voltage;
          }
        }
      }
    } else {
      final base = (mux - 0x18) * 4;
      for (int i = 0; i < 4; i++) {
        final idx = base + i;
        if (idx < 32) {
          int v = values[i];
          if (v & 0x2000 != 0) v -= 0x4000;
          final temp = v * 0.0122;
          _sweepTemps[idx] = temp;
          // Incremental temp update too
          final modIdx = idx ~/ 2;
          if (modIdx < 16) {
            if (idx % 2 == 0) {
              temps[modIdx] = (temp, temps[modIdx].$2);
            } else {
              temps[modIdx] = (temps[modIdx].$1, temp);
            }
          }
        }
      }
    }

    _muxSeen.add(mux);

    if (_muxSeen.length >= 32) {
      // Complete sweep — do a full atomic update with sanity filter
      for (int i = 0; i < 96; i++) {
        final v = _sweepCells[i];
        if (!v.isNaN && v > 0.5 && v < 5.0) {
          cells[i] = v;
        }
      }
      _goodCells = List.from(cells);
      for (int i = 0; i < 16; i++) {
        temps[i] = (_sweepTemps[i * 2], _sweepTemps[i * 2 + 1]);
      }
      _muxSeen.clear();
      _sweepCells.fillRange(0, 96, double.nan);
      _sweepTemps.fillRange(0, 32, double.nan);
      return true;
    }
    return false;
  }

  // ── Feed other CAN IDs ───────────────────────────────────────────────

  void feed102(List<int> data) {
    if (data.length < 2) return;
    packVoltage = ((data[0] << 8) | data[1]) * 0.01;
    if (data.length >= 4) {
      final rawI = (data[2] << 8) | data[3];
      if (rawI == 0xFFFF || rawI == 0x7FFF) {
        packCurrent = double.nan;
      } else {
        int signed = rawI > 0x7FFF ? rawI - 0x10000 : rawI;
        packCurrent = signed * 0.1;
      }
    }
    if (data.length >= 8) {
      final rawT = (data[6] << 8) | data[7];
      // neg terminal temp — scale TBC
    }
  }

  void feed202(List<int> data) {
    if (data.length < 8) return;
    final minV = ((data[0] << 8) | data[1]) * 0.010;
    final maxV = ((data[2] << 8) | data[3]) * 0.010;
    maxChargeCurrent = ((data[4] << 8) | data[5]) * 0.1;
    maxDischargeCurrent = ((data[6] << 8) | data[7]) * 0.12799;
  }

  void feed232(List<int> data) {
    if (data.length < 4) return;
    maxRegenKw = ((data[0] << 8) | data[1]) * 10 / 1000;
    maxDischargeKw = ((data[2] << 8) | data[3]) * 10 / 1000;
  }

  void feed302(List<int> data) {
    if (data.length < 8) return;

    // SoC/SoE only reliable on BMS internal bus — on vehicle bus 0x302 may
    // originate from a different ECU or be multiplexed with a mux byte at [0]
    if (!vehicleBus) {
      final rawSoc = (data[0] << 8) | data[1];
      final rawSoe = (data[2] << 8) | data[3];
      if (rawSoc > 0) {
        final candidate = rawSoc * 0.01;
        if (candidate <= 100.0) soc = candidate;
      }
      if (rawSoe > 0) {
        final candidate = rawSoe * 0.01;
        if (candidate <= 100.0) socSoe = candidate;
      }
    }

    // kWh counter: bytes 4-6, 3 bytes big-endian, 10 Wh/LSB
    final kwhRaw = (data[4] << 16) | (data[5] << 8) | data[6];
    if (kwhRaw > 0) {
      final candidate = kwhRaw * 0.01;
      if (candidate < 500000) {
        if (kwhCharged.isNaN) {
          kwhCharged = candidate;
        } else if (candidate >= kwhCharged && (candidate - kwhCharged) < 500) {
          kwhCharged = candidate;
        }
      }
    }
  }

  /// 0x332 — BMS energy status (vehicle CAN bus, Model S)
  /// Present on OBD-II port; NOT on BMS-internal CAN (where MeatPi connects)
  /// Multiplexed by byte 0 — SoC is in mux 0x00 at bytes 1-2.
  void feed332(List<int> data) {
    if (data.length < 4) return;
    if (data[0] != 0x00) return;
    final rawSoc = (data[1] << 8) | data[2];
    if (rawSoc > 0) {
      final candidate = rawSoc * 0.01;
      if (candidate <= 100.0 && candidate > 0.0) {
        soc = candidate;
      }
    }
  }

  /// 0x392 — BMS power limits (vehicle CAN bus, Model S, multiplexed by byte 0)
  void feed392(List<int> data) {
    if (data.length < 7) return;
    final mux = data[0] & 0x0F;
    switch (mux) {
      case 0x01:
        // Mux 01: power limits (kW), 16-bit LE, 0.01 kW/bit
        final rawRegen = data[2] | (data[3] << 8);
        if (rawRegen > 0) maxRegenKw = rawRegen * 0.01;
        final rawDischgKw = data[4] | (data[5] << 8);
        if (rawDischgKw > 0) maxDischargeKw = rawDischgKw * 0.01;
        break;
      case 0x04:
        // Mux 04: current limits (A), 16-bit LE, 0.1 A/bit
        final rawDischgI = data[3] | (data[4] << 8);
        if (rawDischgI > 0 && rawDischgI < 0xFFFF) {
          maxDischargeCurrent = rawDischgI * 0.1;
          wotCurrentLimit = rawDischgI * 0.1;
        }
        break;
    }
  }

  void feed542(List<int> data) {
    try {
      final trimmed = data.where((b) => b != 0).toList();
      if (trimmed.isEmpty) return;
      if (!trimmed.every((b) => b >= 0x20 && b <= 0x7E)) return;
      serialNumber = String.fromCharCodes(trimmed);
    } catch (_) {}
  }

  void feed552(List<int> data) {
    try {
      final trimmed = data.where((b) => b != 0).toList();
      if (trimmed.isEmpty) return;
      if (!trimmed.every((b) => b >= 0x20 && b <= 0x7E)) return;
      serialNumber += String.fromCharCodes(trimmed);
    } catch (_) {}
  }

  void feed7E2(List<int> data) {
    if (data.isEmpty) return;
    if (data[0] == 0x89 && data.length >= 6) {
      wotCurrentLimit = ((data[4] << 8) | data[5]) * 0.12;
    }
  }
}
