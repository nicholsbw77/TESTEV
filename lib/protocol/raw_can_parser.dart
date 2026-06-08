import 'dart:async';
import 'dart:typed_data';
import 'can_frame.dart';

enum RawFormat { unknown, slcan, binary }

class RawCanParser {
  final _frameController = StreamController<CanFrame>.broadcast();
  Stream<CanFrame> get frameStream => _frameController.stream;

  RawFormat _format = RawFormat.unknown;
  final List<int> _buffer = [];
  int _frameCount = 0;
  int _fps = 0;
  DateTime _fpsTime = DateTime.now();

  RawFormat get detectedFormat => _format;
  int get fps => _fps;

  void setFormat(RawFormat format) {
    _format = format;
  }

  void feedBytes(Uint8List data) {
    _buffer.addAll(data);

    if (_format == RawFormat.unknown && _buffer.isNotEmpty) {
      _detectFormat();
    }

    switch (_format) {
      case RawFormat.slcan:
        _parseSlcan();
        break;
      case RawFormat.binary:
        _parseBinary();
        break;
      case RawFormat.unknown:
        break;
    }

    if (_buffer.length > 8192) {
      _buffer.removeRange(0, _buffer.length - 4096);
    }
  }

  void _detectFormat() {
    // Skip leading whitespace/CR/LF from init responses
    while (_buffer.isNotEmpty &&
           (_buffer[0] == 0x0D || _buffer[0] == 0x0A || _buffer[0] == 0x20)) {
      _buffer.removeAt(0);
    }
    if (_buffer.isEmpty) return;

    final first = _buffer[0];
    if (first == 0x74 || first == 0x54 || first == 0x72 || first == 0x52) {
      // 't', 'T', 'r', 'R' — SLCAN ASCII
      _format = RawFormat.slcan;
    } else if (first == 0xAA) {
      _format = RawFormat.binary;
    } else if (first >= 0x20 && first <= 0x7E) {
      // Printable ASCII but not a known SLCAN prefix — could be init response.
      // Default to SLCAN after enough data accumulates.
      if (_buffer.length > 32) _format = RawFormat.slcan;
    } else {
      _format = RawFormat.binary;
    }
  }

  void _parseSlcan() {
    while (true) {
      final crIdx = _buffer.indexOf(0x0D); // \r
      if (crIdx < 0) break;

      final lineBytes = _buffer.sublist(0, crIdx);
      _buffer.removeRange(0, crIdx + 1);

      if (lineBytes.isEmpty) continue;

      final line = String.fromCharCodes(lineBytes);
      final frame = _parseSlcanLine(line);
      if (frame != null) {
        _countFrame();
        _frameController.add(frame);
      }
    }
  }

  CanFrame? _parseSlcanLine(String line) {
    if (line.isEmpty) return null;
    final type = line[0];

    // t = standard frame, T = extended frame, r/R = RTR (ignore)
    if (type != 't' && type != 'T') return null;

    try {
      if (type == 't') {
        // Standard: tIIILDDDD...
        if (line.length < 5) return null;
        final id = int.parse(line.substring(1, 4), radix: 16);
        final dlc = int.parse(line[4]);
        if (dlc > 8) return null;
        final hexData = line.substring(5, 5 + dlc * 2);
        return CanFrame(
          arbitrationId: id,
          data: _hexToBytes(hexData),
        );
      } else {
        // Extended: TIIIIIIIILDDDD...
        if (line.length < 10) return null;
        final id = int.parse(line.substring(1, 9), radix: 16);
        final dlc = int.parse(line[9]);
        if (dlc > 8) return null;
        final hexData = line.substring(10, 10 + dlc * 2);
        return CanFrame(
          arbitrationId: id,
          data: _hexToBytes(hexData),
          isExtended: true,
        );
      }
    } catch (_) {
      return null;
    }
  }

  void _parseBinary() {
    // MeatPi native binary: [0xAA, id3, id2, id1, id0, dlc, data...]
    while (_buffer.length >= 6) {
      if (_buffer[0] != 0xAA) {
        _buffer.removeAt(0);
        continue;
      }

      final dlc = _buffer[5];
      if (dlc > 8) {
        _buffer.removeAt(0);
        continue;
      }

      if (_buffer.length < 6 + dlc) break;

      final id = (_buffer[1] << 24) | (_buffer[2] << 16) |
                 (_buffer[3] << 8) | _buffer[4];
      final data = Uint8List.fromList(_buffer.sublist(6, 6 + dlc));
      _buffer.removeRange(0, 6 + dlc);

      _frameController.add(CanFrame(
        arbitrationId: id & 0x1FFFFFFF,
        data: data,
        isExtended: id > 0x7FF,
      ));
    }
  }

  Uint8List _hexToBytes(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  void _countFrame() {
    _frameCount++;
    final now = DateTime.now();
    if (now.difference(_fpsTime).inMilliseconds >= 1000) {
      _fps = _frameCount;
      _frameCount = 0;
      _fpsTime = now;
    }
  }

  void dispose() {
    _frameController.close();
  }
}
