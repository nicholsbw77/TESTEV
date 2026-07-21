import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'can_frame.dart';
import 'adapter_base.dart';

/// DEBUG-CAPTURE: raw-frame logging for MeatPi decode diagnosis.
/// IDs we're trying to pin down (SOC/WOT/limits). Remove after fix.
const Set<int> _kCaptureIds = {0x302, 0x332, 0x392, 0x3D2, 0x7E2, 0x202, 0x232};

/// SLCAN over WiFi TCP — for MeatPi WiCAN.
///
/// Connects to [host]:[port] (default 192.168.50.158:3333),
/// sends SLCAN init commands, then reads frames continuously.
class SlcanAdapter extends CanAdapter {
  final String host;
  final int port;
  Socket? _socket;
  String _buffer = '';
  bool _receiving = false;

  SlcanAdapter({
    this.host = '192.168.50.158',
    this.port = 3333,
  }) : super(AdapterType.slcanWifi);

  @override
  Future<void> connect() async {
    _socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    connected = true;

    // SLCAN init sequence
    _socket!.add(utf8.encode('\r'));
    await Future.delayed(const Duration(milliseconds: 100));
    _socket!.add(utf8.encode('C\r'));     // close first
    await Future.delayed(const Duration(milliseconds: 100));
    _socket!.add(utf8.encode('S6\r'));    // 500k bitrate
    await Future.delayed(const Duration(milliseconds: 100));
    _socket!.add(utf8.encode('O\r'));     // open channel
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> disconnect() async {
    _receiving = false;
    connected = false;
    if (_socket != null) {
      try {
        _socket!.add(utf8.encode('C\r'));
        await _socket!.flush();
        await _socket!.close();
      } catch (_) {}
    }
    _socket = null;
  }

  @override
  Future<void> startReceiving(void Function(CanFrame frame) onFrame) async {
    if (_socket == null) return;
    _receiving = true;

    _socket!.listen(
      (data) {
        if (!_receiving) return;
        _buffer += utf8.decode(data, allowMalformed: true);
        _processBuffer(onFrame);
      },
      onError: (e) {
        connected = false;
        _receiving = false;
      },
      onDone: () {
        connected = false;
        _receiving = false;
      },
    );
  }

  void _processBuffer(void Function(CanFrame frame) onFrame) {
    while (_buffer.contains('\r')) {
      final idx = _buffer.indexOf('\r');
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);
      if (line.isNotEmpty) {
        final frame = _parseLine(line);
        if (frame != null) {
          // DEBUG-CAPTURE: emit candump-style ID#hexdata for target IDs.
          if (_kCaptureIds.contains(frame.id)) {
            final hex = frame.data
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase();
            dev.log('${frame.id.toRadixString(16).toUpperCase().padLeft(3, '0')}#$hex',
                name: 'MEATPICAP');
          }
          countFrame();
          onFrame(frame);
        }
      }
    }
  }

  CanFrame? _parseLine(String line) {
    // SLCAN format: t1028DEADBEEF (standard) or T12345678... (extended)
    if (line.isEmpty) return null;
    try {
      if (line[0] == 't') {
        final canId = int.parse(line.substring(1, 4), radix: 16);
        final dlc = int.parse(line[4]);
        final hexData = line.substring(5, 5 + dlc * 2);
        final data = <int>[];
        for (int i = 0; i < hexData.length; i += 2) {
          data.add(int.parse(hexData.substring(i, i + 2), radix: 16));
        }
        return CanFrame(id: canId, data: data);
      } else if (line[0] == 'T') {
        final canId = int.parse(line.substring(1, 9), radix: 16);
        final dlc = int.parse(line[9]);
        final hexData = line.substring(10, 10 + dlc * 2);
        final data = <int>[];
        for (int i = 0; i < hexData.length; i += 2) {
          data.add(int.parse(hexData.substring(i, i + 2), radix: 16));
        }
        return CanFrame(id: canId, data: data);
      }
    } catch (_) {}
    return null;
  }
}
