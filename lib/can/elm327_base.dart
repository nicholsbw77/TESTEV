import 'dart:async';
import 'dart:convert';

import 'adapter_base.dart';
import 'can_frame.dart';

/// Transport-agnostic ELM327/STN logic: init sequence, STN hardware filters,
/// ATMA monitor mode, and hex line parsing.
///
/// Subclasses supply the byte transport:
///  * [Elm327Adapter]   — Bluetooth SPP (Android, flutter_bluetooth_serial)
///  * [Elm327EaAdapter] — MFi ExternalAccessory (iOS, OBDLink MX+)
abstract class Elm327Base extends CanAdapter {
  String _buffer = '';
  bool _receiving = false;
  bool _initialized = false;

  // Status callback for UI progress
  void Function(String)? onStatus;

  Elm327Base(super.type, {this.onStatus});

  // ── transport primitives ─────────────────────────────────────────────

  /// Open the underlying link. Must throw on failure.
  Future<void> openTransport();

  /// Close the underlying link (must not throw).
  Future<void> closeTransport();

  /// Send raw bytes (fire-and-forget).
  void writeBytes(List<int> bytes);

  /// Incoming byte stream — valid after [openTransport] completes.
  Stream<List<int>> inputStream();

  // ── shared ELM/STN protocol ──────────────────────────────────────────

  @override
  Future<void> connect() async {
    await openTransport();
    connected = true;
    onStatus?.call('Connected — initializing ELM327...');

    // ELM327 init sequence
    await _sendCmd('ATZ', delay: 1500); // reset
    await _sendCmd('ATE0', delay: 300); // echo off
    await _sendCmd('ATL0', delay: 300); // linefeeds off
    await _sendCmd('ATH1', delay: 300); // headers on (show CAN ID)
    await _sendCmd('ATS0', delay: 300); // spaces off (compact hex)
    await _sendCmd('ATSP6', delay: 300); // protocol ISO 15765-4 CAN 500k
    await _sendCmd('ATCAF0', delay: 300); // CAN auto-formatting off
    await _sendCmd('ATCSM1', delay: 300); // silent monitoring
    // Accept only the CAN IDs verified present on the vehicle OBD bus.
    // 0x132/0x232/0x302/0x542/0x552 do NOT exist on the vehicle bus.
    // STN chips support multiple STFAP entries (additive pass list).
    await _sendCmd('STFCP', delay: 200); // clear any existing filters
    await _sendCmd('STFAP 132,7FF', delay: 200); // pack voltage/current
    await _sendCmd('STFAP 332,7FF', delay: 200); // SoC
    await _sendCmd('STFAP 392,7FF', delay: 200); // power limits / WOT current
    await _sendCmd('STFAP 6F2,7FF', delay: 200); // cell voltages / temps
    await _sendCmd('STFAP 7E2,7FF', delay: 200); // UDS responses (cell data)

    _initialized = true;
    onStatus?.call('ELM327 initialized — starting monitor mode');
  }

  @override
  Future<void> disconnect() async {
    _receiving = false;
    connected = false;
    _initialized = false;
    try {
      // Exit monitor mode before closing
      writeBytes(utf8.encode('\r'));
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    await closeTransport();
  }

  @override
  Future<void> startReceiving(void Function(CanFrame frame) onFrame) async {
    if (!connected || !_initialized) return;

    // Send ATMA to start monitor-all mode (through the STN filters)
    writeBytes(utf8.encode('ATMA\r'));
    _receiving = true;

    onStatus?.call('Monitor mode active — receiving frames');

    inputStream().listen(
      (data) {
        if (!_receiving) return;
        _buffer += utf8.decode(data, allowMalformed: true);
        _processBuffer(onFrame);
      },
      onError: (e) {
        connected = false;
        _receiving = false;
        onStatus?.call('Link error: $e');
      },
      onDone: () {
        connected = false;
        _receiving = false;
        onStatus?.call('Disconnected');
      },
    );
  }

  Future<void> _sendCmd(String cmd, {int delay = 300}) async {
    _buffer = '';
    writeBytes(utf8.encode('$cmd\r'));
    await Future.delayed(Duration(milliseconds: delay));
  }

  void _processBuffer(void Function(CanFrame frame) onFrame) {
    while (_buffer.contains('\r')) {
      final idx = _buffer.indexOf('\r');
      String line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);

      // Skip empty lines and ELM327 prompts
      if (line.isEmpty ||
          line == '>' ||
          line == 'OK' ||
          line == 'SEARCHING...' ||
          line == 'NO DATA' ||
          line.startsWith('AT') ||
          line.startsWith('ELM') ||
          line.startsWith('STN') ||
          line.contains('?')) {
        continue;
      }

      final frame = _parseLine(line);
      if (frame != null) {
        countFrame();
        onFrame(frame);
      }
    }

    // Prevent buffer from growing unbounded
    if (_buffer.length > 4096) {
      _buffer = _buffer.substring(_buffer.length - 1024);
    }
  }

  CanFrame? _parseLine(String line) {
    // Remove any spaces for uniform parsing
    line = line.replaceAll(' ', '').toUpperCase();

    // Minimum: 3 hex chars for ID + 2 for one data byte = 5
    if (line.length < 5) return null;

    // Validate all hex
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(line)) return null;

    try {
      // First 3 chars are the CAN ID (11-bit, 3 hex digits)
      final canId = int.parse(line.substring(0, 3), radix: 16);
      if (canId > 0x7FF) return null;

      // Remaining chars are data bytes (2 hex chars each)
      final hexData = line.substring(3);
      if (hexData.length % 2 != 0) return null;
      if (hexData.length > 16) return null; // max 8 bytes

      final data = <int>[];
      for (int i = 0; i < hexData.length; i += 2) {
        data.add(int.parse(hexData.substring(i, i + 2), radix: 16));
      }

      return CanFrame(id: canId, data: data);
    } catch (_) {
      return null;
    }
  }
}
