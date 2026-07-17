import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'adapter_base.dart';
import 'elm327_base.dart';

/// ELM327 over Bluetooth SPP — for OBDLink MX+, OBDLink LX, generic ELM327.
///
/// NOTE: flutter_bluetooth_serial is Android-only. On iOS use
/// [Elm327EaAdapter] (MFi ExternalAccessory) instead.
class Elm327Adapter extends Elm327Base {
  final String? deviceAddress; // BT MAC address, or null to scan
  final String? deviceName; // e.g. "OBDLink MX+"
  BluetoothConnection? _connection;

  Elm327Adapter({
    this.deviceAddress,
    this.deviceName,
    super.onStatus,
  }) : super(AdapterType.elm327Bluetooth);

  @override
  Future<void> openTransport() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
          'Bluetooth SPP is only supported on Android.\n'
          'On iOS, use the MFi (ExternalAccessory) connection instead.');
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
  }

  @override
  Future<void> closeTransport() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
  }

  @override
  void writeBytes(List<int> bytes) {
    _connection?.output.add(Uint8List.fromList(bytes));
  }

  @override
  Stream<List<int>> inputStream() =>
      _connection?.input ?? const Stream<List<int>>.empty();
}
