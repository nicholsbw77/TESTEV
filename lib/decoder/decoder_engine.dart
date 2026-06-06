import 'dart:typed_data';
import '../protocol/can_frame.dart';
import '../data/pack_state.dart';
import 'constants.dart';
import 'pack_decoders.dart';
import 'cell_frame_buffer.dart';

class DecoderEngine {
  final PackState state;
  final CellFrameBuffer _cellBuffer = CellFrameBuffer();

  DecoderEngine(this.state);

  double get sweepCompletionPct => _cellBuffer.completionPct;

  void dispatch(CanFrame frame) {
    switch (frame.arbitrationId) {
      case canIdBmsCellBlock:
        _handle6F2(frame.data);
        break;
      case canIdBmsVoltCurr:
        if (!state.vehicleBus) _handle102(frame.data);
        break;
      case canIdVehVoltCurr:
        _handle102(frame.data);
        break;
      case canIdBmsSoc:
        if (!state.vehicleBus) _handle302(frame.data);
        break;
      case canIdBmsContactor:
        _handle312(frame.data);
        break;
      case canIdBmsIsolation:
        _handle322(frame.data);
        break;
      case canIdVehSoc:
        _handle332(frame.data);
        break;
      case canIdVehPowerMux:
        _handle392(frame.data);
        break;
      case canIdVehLimits:
        if (!state.vehicleBus) _handle202(frame.data);
        break;
      case canIdVehPowerLimits:
        if (!state.vehicleBus) _handle232(frame.data);
        break;
      case canIdBmsSerial1:
        _handleSerial(frame.data, first: true);
        break;
      case canIdBmsSerial2:
        _handleSerial(frame.data, first: false);
        break;
      case canIdBmsWot:
        _handle7E2(frame.data);
        break;
    }

    if (_cellBuffer.isTimedOut) {
      final partial = _cellBuffer.partialSnapshot();
      _applyCellSnapshot(partial);
    }
  }

  void _handle6F2(Uint8List data) {
    final snapshot = _cellBuffer.feed(data);
    if (snapshot != null) {
      _applyCellSnapshot(snapshot);
    }
  }

  void _applyCellSnapshot(CellSweepSnapshot snapshot) {
    for (int i = 0; i < numCells; i++) {
      final v = snapshot.cells[i];
      if (!v.isNaN && v > 0.5 && v < 5.0) {
        state.cells[i] = v;
      }
    }
    for (int i = 0; i < numModules; i++) {
      state.temps[i] = snapshot.moduleTemps[i];
    }
  }

  void _handle102(Uint8List data) {
    final r = decode0x102(data);
    if (r == null) return;
    state.packVoltage = r.packVoltage;
    state.packCurrent = r.packCurrent;
    if (r.negTerminalTempC != null) {
      state.negTerminalTempC = r.negTerminalTempC!;
    }
  }

  void _handle202(Uint8List data) {
    if (data.length < 8) return;
    state.maxChargeCurrent = ((data[4] << 8) | data[5]) * 0.1;
    state.maxDischargeCurrent = ((data[6] << 8) | data[7]) * 0.1;
  }

  void _handle232(Uint8List data) {
    if (data.length < 4) return;
    state.maxRegenKw = ((data[0] << 8) | data[1]) * 10 / 1000;
    state.maxDischargeKw = ((data[2] << 8) | data[3]) * 10 / 1000;
  }

  void _handle302(Uint8List data) {
    final r = decode0x302(data);
    if (r == null) return;
    if (r.socPercent > 0 && r.socPercent <= 100) {
      state.soc = r.socPercent;
    }
    state.kwhDischarged = r.kwhDischarged;
    state.kwhCharged = r.kwhCharged;
  }

  void _handle312(Uint8List data) {
    final r = decode0x312(data);
    if (r == null) return;
    state.contactorState = r.state;
  }

  void _handle322(Uint8List data) {
    final r = decode0x322(data);
    if (r == null) return;
    state.isolationKohm = r.isolationKohm;
  }

  void _handle332(Uint8List data) {
    if (data.length < 3) return;
    final avg = state.cellAvg;
    if (avg.isNaN) return;
    final estSoc = ((avg - 3.0) / 1.2 * 100).clamp(0.0, 100.0);

    for (final raw in [
      (data[0] << 8) | data[1],
      (data[1] << 8) | data[2],
    ]) {
      if (raw > 0) {
        final candidate = raw * socScale;
        if (candidate > 0.0 &&
            candidate <= 100.0 &&
            (candidate - estSoc).abs() < 30) {
          state.soc = candidate;
          return;
        }
      }
    }
  }

  void _handle392(Uint8List data) {
    if (data.length < 7) return;
    final mux = data[0] & 0x0F;
    switch (mux) {
      case 0x01:
        final rawDischgKw = (data[1] << 8) | data[2];
        if (rawDischgKw > 1000) state.maxDischargeKw = rawDischgKw * 0.01;
        final rawRegenKw = (data[4] << 8) | data[5];
        if (rawRegenKw > 1000) state.maxRegenKw = rawRegenKw * 0.01;
        break;
      case 0x04:
        final rawDischgI = data[4] | (data[5] << 8);
        if (rawDischgI > 0 && rawDischgI < 0xFFFF) {
          state.maxDischargeCurrent = rawDischgI * 0.1;
          state.wotCurrentLimit = rawDischgI * 0.1;
        }
        break;
    }
  }

  void _handle7E2(Uint8List data) {
    if (data.isEmpty) return;
    if (data[0] == 0x89 && data.length >= 6) {
      state.wotCurrentLimit = ((data[4] << 8) | data[5]) * 0.12;
    }
  }

  void _handleSerial(Uint8List data, {required bool first}) {
    try {
      final trimmed = data.where((b) => b != 0).toList();
      if (trimmed.isEmpty) return;
      if (!trimmed.every((b) => b >= 0x20 && b <= 0x7E)) return;
      if (first) {
        state.serialNumber = String.fromCharCodes(trimmed);
      } else {
        state.serialNumber += String.fromCharCodes(trimmed);
      }
    } catch (_) {}
  }
}
