import 'dart:typed_data';

enum TransportType { bluetooth, wifi, replay }

abstract class AdapterTransport {
  Future<void> connect();
  Future<void> disconnect();
  Stream<Uint8List> get dataStream;
  Future<void> send(Uint8List data);
  bool get isConnected;
  String get adapterName;
  TransportType get type;
}
