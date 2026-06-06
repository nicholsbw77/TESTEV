import 'dart:async';
import 'dart:typed_data';
import 'adapter_transport.dart';

class ReplayFrame {
  final double timestamp;
  final int arbitrationId;
  final Uint8List data;

  const ReplayFrame({
    required this.timestamp,
    required this.arbitrationId,
    required this.data,
  });
}

class ReplayTransport extends AdapterTransport {
  final List<ReplayFrame> frames;
  final double speed;
  final bool loop;

  StreamController<Uint8List>? _dataController;
  bool _connected = false;
  bool _running = false;

  ReplayTransport({
    required this.frames,
    this.speed = 1.0,
    this.loop = true,
  });

  factory ReplayTransport.fromElm327Log(String content,
      {double speed = 1.0, bool loop = true}) {
    final frames = parseElm327Log(content);
    return ReplayTransport(frames: frames, speed: speed, loop: loop);
  }

  factory ReplayTransport.fromCsv(String content,
      {double speed = 1.0, bool loop = true}) {
    final frames = parseCsvLog(content);
    return ReplayTransport(frames: frames, speed: speed, loop: loop);
  }

  @override
  TransportType get type => TransportType.replay;

  @override
  String get adapterName => 'Replay (${frames.length} frames)';

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get dataStream =>
      _dataController?.stream ?? const Stream.empty();

  @override
  Future<void> connect() async {
    _dataController = StreamController<Uint8List>.broadcast();
    _connected = true;
    _running = true;
    _playback();
  }

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> disconnect() async {
    _running = false;
    _connected = false;
    await _dataController?.close();
    _dataController = null;
  }

  Future<void> _playback() async {
    while (_running) {
      if (frames.isEmpty) break;

      final t0 = frames.first.timestamp;
      final wallStart = DateTime.now().microsecondsSinceEpoch / 1e6;

      for (final frame in frames) {
        if (!_running) return;

        final targetWall = wallStart + (frame.timestamp - t0) / speed;
        final now = DateTime.now().microsecondsSinceEpoch / 1e6;
        final sleepMs = ((targetWall - now) * 1000).toInt();
        if (sleepMs > 0) {
          await Future.delayed(Duration(milliseconds: sleepMs));
        }
        if (!_running) return;

        // Emit as ELM327-style line for the protocol layer
        final idHex =
            frame.arbitrationId.toRadixString(16).toUpperCase().padLeft(3, '0');
        final dataHex =
            frame.data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
        final line = '$idHex $dataHex\r';
        _dataController?.add(Uint8List.fromList(line.codeUnits));
      }

      if (!loop) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  static List<ReplayFrame> parseElm327Log(String content) {
    final frames = <ReplayFrame>[];
    final spacedRe = RegExp(
        r'^([0-9A-Fa-f]{3,8})\s+([0-9A-Fa-f]{2}(?:\s+[0-9A-Fa-f]{2})+)$');
    final tightRe = RegExp(r'^([0-9A-Fa-f]{3,8})([0-9A-Fa-f]+)$');
    double ts = 0.0;

    for (final line in content.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final m = spacedRe.firstMatch(trimmed) ?? tightRe.firstMatch(trimmed);
      if (m == null) continue;

      try {
        final arbId = int.parse(m.group(1)!, radix: 16);
        final hexStr = m.group(2)!.replaceAll(' ', '');
        if (hexStr.length % 2 != 0) continue;

        final data = Uint8List(hexStr.length ~/ 2);
        for (int i = 0; i < hexStr.length; i += 2) {
          data[i ~/ 2] = int.parse(hexStr.substring(i, i + 2), radix: 16);
        }

        frames.add(ReplayFrame(
          timestamp: ts,
          arbitrationId: arbId,
          data: data,
        ));
        ts += 0.001;
      } catch (_) {}
    }
    return frames;
  }

  static List<ReplayFrame> parseCsvLog(String content) {
    final frames = <ReplayFrame>[];
    final lines = content.split(RegExp(r'[\r\n]+'));
    double ts = 0.0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      // CSV: timestamp,id,data_hex  or  id,data_hex
      final parts = trimmed.split(',');
      if (parts.length < 2) continue;

      try {
        int idIdx = 0;
        if (parts.length >= 3) {
          // Try timestamp in first column
          final maybeTs = double.tryParse(parts[0]);
          if (maybeTs != null) {
            ts = maybeTs;
            idIdx = 1;
          }
        }

        final idStr = parts[idIdx].trim();
        final arbId = int.parse(
            idStr.startsWith('0x') ? idStr.substring(2) : idStr,
            radix: 16);

        final hexStr = parts[idIdx + 1].trim().replaceAll(' ', '');
        if (hexStr.length % 2 != 0) continue;

        final data = Uint8List(hexStr.length ~/ 2);
        for (int i = 0; i < hexStr.length; i += 2) {
          data[i ~/ 2] = int.parse(hexStr.substring(i, i + 2), radix: 16);
        }

        frames.add(ReplayFrame(
          timestamp: ts,
          arbitrationId: arbId,
          data: data,
        ));
        if (idIdx == 0) ts += 0.001;
      } catch (_) {}
    }
    return frames;
  }
}
