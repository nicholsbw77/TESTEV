import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'can_frame.dart';
import 'adapter_base.dart';

/// DEBUG-CAPTURE: raw-frame logging for MeatPi decode diagnosis.
/// IDs we're trying to pin down (SOC/WOT/limits). Remove after fix.
const Set<int> _kCaptureIds = {0x302, 0x332, 0x392, 0x3D2, 0x7E2, 0x202, 0x232};

/// SLCAN over WiFi TCP — for MeatPi WiCAN in **native SLCAN mode**
/// (NOT ELM327 emulator).
///
/// Connects to [host]:[port] (default 192.168.50.158:3333), sends the
/// standard SLCAN open sequence (`C\r S6\r O\r`), then continuously
/// parses `t...\r` frames into a **broadcast** [frameStream].
///
/// Because the underlying [frameStream] is a broadcast controller, both
/// the dashboard monitor path (via [startReceiving]) and the BMS-Clear
/// UDS path (via [frameStream] directly) can consume the same frames
/// without stealing a single-subscription — nothing has to compete for
/// the socket.
///
/// [sendFrame] writes an outgoing frame in the same `t...\r` slcan form,
/// which the WiCAN then transmits on the CAN bus. This is what the Python
/// `tools/wican_uds.py` reference does inline.
class SlcanAdapter extends CanAdapter {
  final String host;
  final int port;
  Socket? _socket;
  StreamSubscription<List<int>>? _socketSub;
  String _buffer = '';
  final StreamController<CanFrame> _frameController =
      StreamController<CanFrame>.broadcast();

  SlcanAdapter({
    this.host = '192.168.50.158',
    this.port = 3333,
  }) : super(AdapterType.slcanWifi);

  /// Broadcast stream of every parsed inbound CAN frame. Safe to listen
  /// from multiple places (dashboard monitor + BMS-Clear ISO-TP) at once.
  Stream<CanFrame> get frameStream => _frameController.stream;

  @override
  Future<void> connect() async {
    _socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    connected = true;

    // Start pumping incoming bytes into parsed frames immediately, so the
    // BMS-Clear path can consume replies without having to call
    // startReceiving() first.
    _socketSub = _socket!.listen(
      _onSocketData,
      onError: (_) {
        connected = false;
      },
      onDone: () {
        connected = false;
      },
    );

    // Standard SLCAN open sequence.
    _socket!.add(utf8.encode('\r'));
    await Future.delayed(const Duration(milliseconds: 100));
    _socket!.add(utf8.encode('C\r'));   // close first
    await Future.delayed(const Duration(milliseconds: 100));
    _socket!.add(utf8.encode('S6\r'));  // 500k bitrate
    await Future.delayed(const Duration(milliseconds: 100));
    _socket!.add(utf8.encode('O\r'));   // open channel
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    await _socketSub?.cancel();
    _socketSub = null;
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
    _frameController.stream.listen((frame) {
      // DEBUG-CAPTURE: emit candump-style ID#hexdata for target IDs.
      if (_kCaptureIds.contains(frame.id)) {
        final hex = frame.data
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();
        dev.log(
            '${frame.id.toRadixString(16).toUpperCase().padLeft(3, '0')}#$hex',
            name: 'MEATPICAP');
      }
      countFrame();
      onFrame(frame);
    });
  }

  /// Send a standard 11-bit CAN frame via the slcan protocol.
  /// Wire form matches Python `wican_uds.py::slcan_send_frame`:
  ///     t{id:03X}{dlc:X}{hex}\r
  void sendFrame(int canId, List<int> data) {
    if (_socket == null) {
      throw StateError('SlcanAdapter is not connected');
    }
    if (canId < 0 || canId > 0x7FF) {
      throw ArgumentError('11-bit CAN IDs only (got 0x${canId.toRadixString(16)})');
    }
    if (data.length > 8) {
      throw ArgumentError('CAN payload > 8 bytes');
    }
    final idHex = canId.toRadixString(16).toUpperCase().padLeft(3, '0');
    final dlc = data.length.toRadixString(16).toUpperCase();
    final buf = StringBuffer('t')..write(idHex)..write(dlc);
    for (final b in data) {
      buf.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    buf.write('\r');
    _socket!.add(utf8.encode(buf.toString()));
  }

  void _onSocketData(List<int> data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    while (_buffer.contains('\r')) {
      final idx = _buffer.indexOf('\r');
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);
      if (line.isEmpty) continue;
      final frame = _parseLine(line);
      if (frame != null) {
        _frameController.add(frame);
      }
    }
    // Guard against unbounded growth if we're receiving partial frames.
    if (_buffer.length > 4096) {
      _buffer = _buffer.substring(_buffer.length - 1024);
    }
  }

  CanFrame? _parseLine(String line) {
    // SLCAN format: t1028DEADBEEF (standard) or T12345678... (extended).
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
