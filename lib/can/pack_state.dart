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

  // Energy currently stored in the pack (kWh) — from 0x382 nominal energy
  // remaining on the BMS internal bus. Falls back to SOC×capacity estimate.
  double currentKwh = double.nan;

  // Nominal usable pack capacity (kWh) for the SOC-based fallback estimate.
  // Classic Model S 85 pack ≈ 77 kWh usable; refine once 0x382 is decoded.
  double nominalPackKwh = 77.0;

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
  DateTime _sweepStart = DateTime.now();

  // ── Computed properties ──────────────────────────────────────────────

  /// Pack voltage computed from summing all valid cell voltages
  double get packVoltageFromCells {
    final vc = validCells;
    if (vc.isEmpty) return 0.0;
    return vc.reduce((a, b) => a + b);
  }

  /// Best available pack voltage — prefer cell sum when complete, fall back to CAN,
  /// then estimate from average cell voltage × 96 when partial cells available
  double get bestPackVoltage {
    final fromCells = packVoltageFromCells;
    final validCount = validCells.length;
    if (fromCells > 50 && validCount >= 90) return fromCells;
    if (packVoltage > 50) return packVoltage;
    if (validCount >= 20) return cellAvg * 96;
    return fromCells;
  }

  /// Energy currently in the pack (kWh). Prefer the directly-decoded 0x382
  /// value; fall back to SOC × nominal usable capacity when unavailable.
  double get bestCurrentKwh {
    if (!currentKwh.isNaN && currentKwh > 0) return currentKwh;
    if (!soc.isNaN) return soc / 100.0 * nominalPackKwh;
    return double.nan;
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
          // CAN 0x6F2 uses 5.0V full-scale (0.000305 V/count) vs
          // bq76PL536 register direct-read 6.25V full-scale (0.000382 V/count).
          // Ratio = 1.25x. Both produce the same voltage for the same cell.
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
          // CAN 0x6F2 temp frames appear to carry pre-converted °C (signed,
          // 0.0122 °C/bit). If temps read wrong, the BMS may send raw 14-bit
          // NTC ADC counts instead — use Beta equation:
          //   ratio = raw/16383; r_ntc = 33046 * ratio / (1 - ratio);
          //   T = 1/(1/298.15 + ln(r_ntc/10000)/4365) - 273.15
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

    // Reset stale sweep if >10 seconds without completing all 32 mux frames
    if (_muxSeen.isNotEmpty &&
        DateTime.now().difference(_sweepStart).inSeconds > 10) {
      _muxSeen.clear();
      _sweepCells.fillRange(0, 96, double.nan);
      _sweepTemps.fillRange(0, 32, double.nan);
    }

    if (_muxSeen.isEmpty) _sweepStart = DateTime.now();
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
    maxDischargeCurrent = ((data[6] << 8) | data[7]) * 0.1;
  }

  void feed232(List<int> data) {
    if (data.length < 4) return;
    maxRegenKw = ((data[0] << 8) | data[1]) * 10 / 1000;
    maxDischargeKw = ((data[2] << 8) | data[3]) * 10 / 1000;
  }

  void feed302(List<int> data) {
    if (data.length < 8) return;

    if (!vehicleBus) {
      // BMS internal bus: upper 6 bits of byte 0 are flags, SOC is 10-bit
      // value in lower 2 bits of byte 0 + all of byte 1, scale 0.1%/bit.
      final rawSoc = ((data[0] & 0x03) << 8) | data[1];
      if (rawSoc > 0) {
        final candidate = rawSoc * 0.1;
        if (candidate <= 100.0) soc = candidate;
      }

      // kWh discharged: bytes [2:3] BE, 0.01 kWh/bit
      final rawOut = (data[2] << 8) | data[3];
      if (rawOut > 0) {
        final candidate = rawOut * 0.01;
        if (candidate < 500000) kwhDischarged = candidate;
      }

      // kWh charged: bytes [4:5] BE, 0.01 kWh/bit
      final rawIn = (data[4] << 8) | data[5];
      if (rawIn > 0) {
        final candidate = rawIn * 0.01;
        if (candidate < 500000) kwhCharged = candidate;
      }
    }
  }

  /// 0x332 — BMS energy status (vehicle CAN bus, Model S)
  /// Cross-validates against cell voltage estimate to reject garbage from
  /// multiplexed frames where byte layout is ambiguous.
  void feed332(List<int> data) {
    if (data.length < 3) return;
    final avg = cellAvg;
    if (avg.isNaN) return;
    final estSoc = ((avg - 3.0) / 1.2 * 100).clamp(0.0, 100.0);

    // Try bytes [0:1] (non-muxed) then [1:2] (muxed, byte 0 = mux counter)
    for (final raw in [
      (data[0] << 8) | data[1],
      (data[1] << 8) | data[2],
    ]) {
      if (raw > 0) {
        final candidate = raw * 0.01;
        if (candidate > 0.0 && candidate <= 100.0 &&
            (candidate - estSoc).abs() < 30) {
          soc = candidate;
          return;
        }
      }
    }
  }

  /// 0x392 — BMS power limits (vehicle CAN bus, Model S, multiplexed by byte 0)
  /// Verified against raw CAN capture: mux cycles 0x01-0x07.
  void feed392(List<int> data) {
    if (data.length < 7) return;
    final mux = data[0] & 0x0F;
    switch (mux) {
      case 0x01:
        // Mux 01: power limits (kW) — bytes [1:2] BE, 0.01 kW/bit
        // Raw data shows ~0xFF0F (652 kW) matching MeatPi's 0x232 value (~631 kW).
        // Some frames carry transitional 0-value; reject those with > 1000 raw threshold.
        final rawDischgKw = (data[1] << 8) | data[2];
        if (rawDischgKw > 1000) maxDischargeKw = rawDischgKw * 0.01;
        final rawRegenKw = (data[4] << 8) | data[5];
        if (rawRegenKw > 1000) maxRegenKw = rawRegenKw * 0.01;
        break;
      case 0x04:
        // Mux 04: current limits — bytes [4:5] LE, 0.1 A/bit
        // Raw data: data[4:5] LE ≈ 0xAA0B (43531) → 4353 A, matches MeatPi feed7E2 (~4403 A).
        // feed7E2 never fires on vehicle bus (data[0] ≠ 0x89), so this is the sole WOT source.
        final rawDischgI = data[4] | (data[5] << 8);
        if (rawDischgI > 0 && rawDischgI < 0xFFFF) {
          maxDischargeCurrent = rawDischgI * 0.1;
          wotCurrentLimit = rawDischgI * 0.1;
        }
        break;
    }
  }

  /// 0x382 — BMS energy status (classic Model S BMS internal bus).
  /// Three 10-bit LE (Intel byte-order) fields at bit offsets 0, 10, 20,
  /// each scaled 0.1 kWh/bit. Matches community DBC and Python reference.
  void feed382(List<int> data) {
    if (data.length < 8) return;
    final raw = _le64(data);
    final nomRemaining = ((raw >> 10) & 0x3FF) * 0.1;
    if (nomRemaining > 0 && nomRemaining < 120) currentKwh = nomRemaining;
  }

  static int _le64(List<int> d) {
    int v = 0;
    for (int i = 7; i >= 0; i--) {
      v = (v << 8) | (i < d.length ? d[i] : 0);
    }
    return v;
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
