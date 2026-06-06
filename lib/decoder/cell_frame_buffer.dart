import 'dart:typed_data';
import 'constants.dart';

class CellSweepSnapshot {
  final List<double> cells;
  final List<(double, double)> moduleTemps;

  const CellSweepSnapshot({required this.cells, required this.moduleTemps});
}

class CellFrameBuffer {
  final List<double> _cells = List.filled(numCells, double.nan);
  final List<double> _temps = List.filled(32, double.nan);
  final Set<int> _seen = {};
  DateTime _sweepStart = DateTime.now();

  double get completionPct => _seen.length / totalMuxFrames * 100;

  CellSweepSnapshot? feed(Uint8List data) {
    if (data.length < 8) return null;

    final mux = data[0];
    if (mux > muxTempMax) return null;

    // 56-bit payload little-endian from bytes 1-7
    int raw = 0;
    for (int i = 7; i >= 1; i--) {
      raw = (raw << 8) | data[i];
    }

    final values = List.generate(
      valuesPerFrame,
      (i) => (raw >> (i * bitsPerValue)) & valueMask,
    );

    if (mux <= muxCellMax) {
      final base = mux * valuesPerFrame;
      for (int i = 0; i < valuesPerFrame; i++) {
        final idx = base + i;
        if (idx < numCells) {
          _cells[idx] =
              (values[i] * cellVoltageScale + cellVoltageOffset) *
              cellVoltageFactor;
        }
      }
    } else {
      final base = (mux - muxTempMin) * valuesPerFrame;
      for (int i = 0; i < valuesPerFrame; i++) {
        final idx = base + i;
        if (idx < 32) {
          int v = values[i];
          if (v & 0x2000 != 0) v -= 0x4000;
          final tempC = v * cellTempScale;
          _temps[idx] =
              (tempC >= tempMinValid && tempC <= tempMaxValid)
                  ? tempC
                  : double.nan;
        }
      }
    }

    if (_seen.isEmpty) _sweepStart = DateTime.now();
    _seen.add(mux);

    if (_seen.length >= totalMuxFrames) {
      final result = _snapshot();
      _seen.clear();
      return result;
    }

    return null;
  }

  CellSweepSnapshot partialSnapshot() => _snapshot();

  bool get isTimedOut =>
      _seen.isNotEmpty &&
      DateTime.now().difference(_sweepStart).inMilliseconds >
          (canSweepTimeoutS * 1000).toInt();

  CellSweepSnapshot _snapshot() {
    final cells = List<double>.from(_cells);
    final moduleTemps = List.generate(
      numModules,
      (i) => (_temps[i * 2], _temps[i * 2 + 1]),
    );
    return CellSweepSnapshot(cells: cells, moduleTemps: moduleTemps);
  }
}
