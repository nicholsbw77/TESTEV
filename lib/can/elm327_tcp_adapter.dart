import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'adapter_base.dart';
import 'elm327_base.dart';

/// ELM327 over a raw TCP socket — for a MeatPi WiCAN configured in
/// **ELM327 emulator mode** (WiCAN web UI → protocol = "ELM327 emulator"),
/// or any other TCP-serial bridge that exposes an ELM327 command surface.
///
/// The wire semantics are identical to the Bluetooth SPP variant; only the
/// byte transport changes. All the AT command sequencing, ATMA parsing,
/// UDS request/response — everything on top of [Elm327Base] — is reused.
class Elm327TcpAdapter extends Elm327Base {
  final String host;
  final int port;
  Socket? _socket;

  Elm327TcpAdapter({
    required this.host,
    required this.port,
    super.onStatus,
  }) : super(AdapterType.elm327WiFi);

  @override
  Future<void> openTransport() async {
    onStatus?.call('Connecting to $host:$port...');
    _socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    // Disable Nagle so tiny AT commands aren't held for coalescing.
    _socket!.setOption(SocketOption.tcpNoDelay, true);
  }

  @override
  Future<void> closeTransport() async {
    try {
      await _socket?.flush();
    } catch (_) {}
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  @override
  void writeBytes(List<int> bytes) {
    _socket?.add(Uint8List.fromList(bytes));
  }

  @override
  Stream<List<int>> inputStream() =>
      _socket ?? const Stream<List<int>>.empty();
}
