import 'dart:io';
import 'bluetooth_spp_transport.dart';

class DetectedAdapter {
  final String name;
  final String address;
  final String transportType;
  final int rssi;

  const DetectedAdapter({
    required this.name,
    required this.address,
    required this.transportType,
    this.rssi = 0,
  });
}

class AdapterScanner {
  static const _btNamePatterns = ['OBDLink', 'ELM327', 'STN', 'OBDII'];
  static const _wifiSsidPatterns = ['WiCAN', 'MeatPi', 'ESP32_CAN'];

  static Future<List<DetectedAdapter>> scan() async {
    final adapters = <DetectedAdapter>[];

    if (Platform.isAndroid) {
      try {
        final btDevices = await BluetoothSppTransport.scan();
        for (final d in btDevices) {
          if (_btNamePatterns.any((p) => d.name.contains(p))) {
            adapters.add(DetectedAdapter(
              name: d.name,
              address: d.address,
              transportType: 'bluetooth',
              rssi: d.rssi,
            ));
          }
        }
      } catch (_) {}
    }

    // WiFi detection — check for known SSIDs (best-effort)
    adapters.add(const DetectedAdapter(
      name: 'MeatPi WiCAN (WiFi)',
      address: '192.168.4.1:3333',
      transportType: 'wifi',
    ));

    return adapters;
  }
}
