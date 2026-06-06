import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'adapter_transport.dart';

class WifiTcpTransport extends AdapterTransport {
  final String host;
  final int port;

  Socket? _socket;
  StreamController<Uint8List>? _dataController;
  bool _connected = false;

  WifiTcpTransport({this.host = '192.168.4.1', this.port = 3333});

  @override
  TransportType get type => TransportType.wifi;

  @override
  String get adapterName => 'MeatPi WiCAN ($host:$port)';

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get dataStream =>
      _dataController?.stream ?? const Stream.empty();

  @override
  Future<void> connect() async {
    _dataController = StreamController<Uint8List>.broadcast();

    _socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    _connected = true;

    _socket!.listen(
      (data) => _dataController?.add(Uint8List.fromList(data)),
      onError: (e) {
        _connected = false;
        _dataController?.addError(e);
      },
      onDone: () {
        _connected = false;
        _dataController?.close();
      },
    );
  }

  @override
  Future<void> send(Uint8List data) async {
    _socket?.add(data);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _socket?.close();
    _socket = null;
    await _dataController?.close();
    _dataController = null;
  }
}
