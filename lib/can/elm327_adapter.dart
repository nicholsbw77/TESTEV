import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'can_frame.dart';
import 'adapter_base.dart';

/// ELM327 over Bluetooth SPP — for OBDLink MX+, OBDLink LX, generic ELM327.
///
/// Sends AT init commands, then ATMA to monitor all CAN traffic.
/// Parses the hex output lines into CAN frames.
///
/// NOTE: flutter_bluetooth_serial is Android-only. On iOS, connect() throws
/// an UnsupportedError. The connect screen guards this with a Platform check.
class Elm327Adapter extends CanAdapter {
  final String? deviceAddress;  // BT MAC address, or null to scan
  final String? deviceName;     // e.g. "OBDLink MX+"
  BluetoothConnection? _connection;
  String _buffer = '';
  bool _receiving = false;
  bool _initialized = false;

  // Status callback for UI progress
  void Function(String)? onStatus;

  Elm327Adapter({
    this.deviceAddress,
    this.deviceName,
    this.onStatus,
  }) : super(AdapterType.elm327Bluetooth);

  @override
  Future<void> connect() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Bluetooth ELM327 is only supported on Android.\n'
        'On iOS, use the MeatPi WiCAN (WiFi) connection instead.');
    }

    // If no address specified, find the OBDLink by name
    String? address = deviceAddress;
    if (address == null) {
      onStatus?.call('Scanning for Bluetooth devices...');
      final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      for (final d in devices) {
        if (d.name != null &&
            (d.name!.contains('OBDLink') ||
             d.name!.contains('ELM327') ||
             d.name!.contains('OBDII') ||
             (deviceName != null && d.name!.contains(deviceName!)))) {
          address = d.address;
          onStatus?.call('Found ${d.name} at ${d.address}');
          break;
        }
      }
      if (address == null) {
        throw Exception(
            'No OBDLink/ELM327 found in paired devices.\n'
            'Pair the device in Bluetooth settings first.');
      }
    }

    onStatus?.call('Connecting to $address...');
    _connection = await BluetoothConnection.toAddress(address);
    connected = true;
    onStatus?.call('Connected — initializing ELM327...');

    // ELM327 init sequence
    await _sendCmd('ATZ', delay: 1500);    // reset
    await _sendCmd('ATE0', delay: 300);    // echo off
    await _sendCmd('ATL0', delay: 300);    // linefeeds off
    await _sendCmd('ATH1', delay: 300);    // headers on (show CAN ID)
    await _sendCmd('ATS0', delay: 300);    // spaces off (compact hex)
    await _sendCmd('ATSP6', delay: 300);   // protocol ISO 15765-4 CAN 500k
    await _sendCmd('ATCAF0', delay: 300);  // CAN auto-formatting off
    await _sendCmd('ATCSM1', delay: 300);  // silent monitoring
    // Accept only the CAN IDs verified present on the vehicle OBD bus.
    // 0x132/0x232/0x302/0x542/0x552 do NOT exist on the vehicle bus.
    // STN chips support multiple STFAP entries (additive pass list).
    await _sendCmd('STFCP', delay: 200);       // clear any existing filters
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
    if (_connection != null) {
      try {
        // Exit monitor mode and close
        _connection!.output.add(Uint8List.fromList(utf8.encode('\r')));
        await Future.delayed(const Duration(milliseconds: 200));
        await _connection!.close();
      } catch (_) {}
    }
    _connection = null;
  }

  @override
  Future<void> startReceiving(void Function(CanFrame frame) onFrame) async {
    if (_connection == null || !_initialized) return;

    // Send ATMA to start monitor-all mode
    _connection!.output.add(Uint8List.fromList(utf8.encode('ATMA\r')));
    _receiving = true;

    onStatus?.call('Monitor mode active — receiving frames');

    _connection!.input?.listen(
      (data) {
        if (!_receiving) return;
        _buffer += utf8.decode(data, allowMalformed: true);
        _processBuffer(onFrame);
      },
      onError: (e) {
        connected = false;
        _receiving = false;
        onStatus?.call('Bluetooth error: $e');
      },
      onDone: () {
        connected = false;
        _receiving = false;
        onStatus?.call('Bluetooth disconnected');
      },
    );
  }

  Future<String> _sendCmd(String cmd, {int delay = 300}) async {
    if (_connection == null) return '';
    _buffer = '';
    _connection!.output.add(Uint8List.fromList(utf8.encode('$cmd\r')));
    await Future.delayed(Duration(milliseconds: delay));
    final response = _buffer.trim();
    _buffer = '';
    return response;
  }

  void _processBuffer(void Function(CanFrame frame) onFrame) {
    while (_buffer.contains('\r')) {
      final idx = _buffer.indexOf('\r');
      String line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);

      // Skip empty lines and ELM327 prompts
      if (line.isEmpty || line == '>' || line == 'OK' ||
          line == 'SEARCHING...' || line == 'NO DATA' ||
          line.startsWith('AT') || line.startsWith('ELM') ||
          line.startsWith('STN') || line.contains('?')) {
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
      if (hexData.length > 16) return null;  // max 8 bytes

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
