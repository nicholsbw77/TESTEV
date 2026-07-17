/// Dart API for the iOS ExternalAccessory (MFi) bridge.
///
/// iOS only — calling these on other platforms throws
/// MissingPluginException; callers gate on Platform.isIOS.
library;

import 'package:flutter/services.dart';

class EaAccessoryInfo {
  final String name;
  final String manufacturer;
  final String modelNumber;
  final List<String> protocols;

  EaAccessoryInfo({
    required this.name,
    required this.manufacturer,
    required this.modelNumber,
    required this.protocols,
  });

  factory EaAccessoryInfo.fromMap(Map<Object?, Object?> m) => EaAccessoryInfo(
        name: (m['name'] ?? '') as String,
        manufacturer: (m['manufacturer'] ?? '') as String,
        modelNumber: (m['modelNumber'] ?? '') as String,
        protocols: List<String>.from((m['protocols'] ?? const []) as List),
      );

  @override
  String toString() => '$name [$manufacturer] protocols: ${protocols.join(', ')}';
}

class EaAccessory {
  static const MethodChannel _channel = MethodChannel('testev/ea_accessory');
  static const EventChannel _events =
      EventChannel('testev/ea_accessory/stream');
  static Stream<Uint8List>? _input;

  /// Currently connected (paired + in-range) MFi accessories.
  static Future<List<EaAccessoryInfo>> listAccessories() async {
    final raw = await _channel.invokeListMethod<dynamic>('listAccessories');
    return (raw ?? const [])
        .map((e) => EaAccessoryInfo.fromMap(e as Map<Object?, Object?>))
        .toList();
  }

  /// Protocol strings declared in this build's Info.plist
  /// (UISupportedExternalAccessoryProtocols).
  static Future<List<String>> declaredProtocols() async =>
      (await _channel.invokeListMethod<String>('declaredProtocols')) ??
      const [];

  /// Opens an EASession with the first accessory advertising [protocol].
  /// Returns the accessory name.
  static Future<String?> connect(String protocol) =>
      _channel.invokeMethod<String>('connect', {'protocol': protocol});

  static Future<void> write(Uint8List data) =>
      _channel.invokeMethod<void>('write', {'data': data});

  static Future<void> disconnect() =>
      _channel.invokeMethod<void>('disconnect');

  /// Incoming bytes from the accessory.
  static Stream<Uint8List> get input => _input ??= _events
      .receiveBroadcastStream()
      .map((e) => e as Uint8List)
      .asBroadcastStream();
}
