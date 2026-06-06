import 'dart:async';
import 'dart:typed_data';
import 'can_frame.dart';

class Elm327Engine {
  static const _initCommands = [
    'ATZ',
    'ATE0',
    'ATL0',
    'ATH1',
    'ATCAF0',
    'ATCSM1',
  ];

  static final _frameRe =
      RegExp(r'([0-9A-Fa-f]{3,8})\s+([0-9A-Fa-f]{2}(?:\s+[0-9A-Fa-f]{2}){0,7})');
  static final _compactRe = RegExp(r'^[0-9A-Fa-f]{5,19}$');

  final _frameController = StreamController<CanFrame>.broadcast();
  Stream<CanFrame> get frameStream => _frameController.stream;

  String _buffer = '';
  int _frameCount = 0;
  int _fps = 0;
  DateTime _fpsTime = DateTime.now();
  DateTime _lastFrame = DateTime.now();
  bool _initialized = false;

  int get fps => _fps;
  bool get isInitialized => _initialized;

  List<Uint8List> buildInitSequence({List<String>? stfapFilters}) {
    final cmds = <Uint8List>[];
    for (final cmd in _initCommands) {
      cmds.add(_encode(cmd));
    }
    if (stfapFilters != null && stfapFilters.isNotEmpty) {
      cmds.add(_encode('STFCP'));
      for (final f in stfapFilters) {
        cmds.add(_encode('STFAP $f'));
      }
    }
    cmds.add(_encode('ATMA'));
    return cmds;
  }

  void markInitialized() {
    _initialized = true;
  }

  void feedBytes(Uint8List bytes) {
    _buffer += String.fromCharCodes(bytes);
    _processBuffer();
  }

  void feedString(String data) {
    _buffer += data;
    _processBuffer();
  }

  void _processBuffer() {
    while (_buffer.contains('\r')) {
      final idx = _buffer.indexOf('\r');
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);

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
        _countFrame();
        _frameController.add(frame);
      }
    }

    if (_buffer.length > 4096) {
      _buffer = _buffer.substring(_buffer.length - 1024);
    }
  }

  CanFrame? _parseLine(String line) {
    // Try spaced format first (standard ELM327 output)
    final m = _frameRe.firstMatch(line);
    if (m != null) {
      try {
        final arbId = int.parse(m.group(1)!, radix: 16);
        final hexData = m.group(2)!.replaceAll(' ', '');
        final data = _hexToBytes(hexData);
        if (data != null) {
          return CanFrame(
            arbitrationId: arbId,
            data: data,
            isExtended: arbId > 0x7FF,
          );
        }
      } catch (_) {}
      return null;
    }

    // Try compact format (no spaces): "6F21868DC6A3..."
    final clean = line.replaceAll(' ', '').toUpperCase();
    if (_compactRe.hasMatch(clean) && clean.length >= 5) {
      try {
        final arbId = int.parse(clean.substring(0, 3), radix: 16);
        if (arbId > 0x7FF) return null;
        final hexData = clean.substring(3);
        if (hexData.length % 2 != 0 || hexData.length > 16) return null;
        final data = _hexToBytes(hexData);
        if (data != null) {
          return CanFrame(arbitrationId: arbId, data: data);
        }
      } catch (_) {}
    }

    return null;
  }

  Uint8List? _hexToBytes(String hex) {
    if (hex.length % 2 != 0) return null;
    try {
      final bytes = Uint8List(hex.length ~/ 2);
      for (int i = 0; i < hex.length; i += 2) {
        bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _countFrame() {
    _frameCount++;
    _lastFrame = DateTime.now();
    final now = DateTime.now();
    if (now.difference(_fpsTime).inMilliseconds >= 1000) {
      _fps = _frameCount;
      _frameCount = 0;
      _fpsTime = now;
    }
  }

  bool get isStalled =>
      _initialized &&
      DateTime.now().difference(_lastFrame).inSeconds > 2;

  Uint8List restartCommand() => _encode('ATMA');

  Uint8List _encode(String cmd) =>
      Uint8List.fromList('$cmd\r'.codeUnits);

  void dispose() {
    _frameController.close();
  }
}
