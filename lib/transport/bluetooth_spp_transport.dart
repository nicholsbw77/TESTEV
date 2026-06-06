import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'adapter_transport.dart';

class BluetoothDevice {
  final String name;
  final String address;
  final int rssi;

  const BluetoothDevice({
    required this.name,
    required this.address,
    this.rssi = 0,
  });
}

class BluetoothSppTransport extends AdapterTransport {
  static const _methodChannel = MethodChannel('testev/bluetooth');
  static const _eventChannel = EventChannel('testev/bluetooth/data');

  final String? deviceAddress;
  final String? deviceName;

  StreamController<Uint8List>? _dataController;
  StreamSubscription? _eventSub;
  bool _connected = false;

  BluetoothSppTransport({this.deviceAddress, this.deviceName});

  @override
  TransportType get type => TransportType.bluetooth;

  @override
  String get adapterName => deviceName ?? 'Bluetooth ($deviceAddress)';

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get dataStream =>
      _dataController?.stream ?? const Stream.empty();

  @override
  Future<void> connect() async {
    _dataController = StreamController<Uint8List>.broadcast();

    String? address = deviceAddress;
    if (address == null && deviceName != null) {
      final devices = await scan();
      final match = devices.where((d) =>
          d.name.contains(deviceName!) ||
          d.name.contains('OBDLink') ||
          d.name.contains('ELM327')).toList();
      if (match.isEmpty) {
        throw Exception('No matching Bluetooth device found for "$deviceName"');
      }
      address = match.first.address;
    }

    if (address == null) {
      throw Exception('No Bluetooth device address specified');
    }

    await _methodChannel.invokeMethod('connect', {'address': address});
    _connected = true;

    _eventSub = _eventChannel
        .receiveBroadcastStream()
        .listen(
          (data) {
            if (data is Uint8List) {
              _dataController?.add(data);
            } else if (data is List) {
              _dataController?.add(Uint8List.fromList(data.cast<int>()));
            }
          },
          onError: (e) {
            _connected = false;
            _dataController?.addError(e);
          },
          onDone: () {
            _connected = false;
          },
        );
  }

  @override
  Future<void> send(Uint8List data) async {
    await _methodChannel.invokeMethod('send', {'data': data});
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _methodChannel.invokeMethod('disconnect');
    } catch (_) {}
    await _dataController?.close();
    _dataController = null;
  }

  static Future<List<BluetoothDevice>> scan() async {
    final result = await _methodChannel.invokeMethod('scan');
    if (result is! List) return [];
    return result.map((d) {
      final map = Map<String, dynamic>.from(d as Map);
      return BluetoothDevice(
        name: map['name'] as String? ?? '',
        address: map['address'] as String? ?? '',
        rssi: map['rssi'] as int? ?? 0,
      );
    }).toList();
  }
}
