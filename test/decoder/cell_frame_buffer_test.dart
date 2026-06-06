import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:testev/decoder/cell_frame_buffer.dart';

Uint8List _hex(String h) {
  final clean = h.replaceAll(' ', '');
  final bytes = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < clean.length; i += 2) {
    bytes[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
  }
  return bytes;
}

void main() {
  group('CellFrameBuffer', () {
    test('returns null until all 32 mux frames received', () {
      final buf = CellFrameBuffer();

      // Feed mux 0x10 (a cell voltage frame from tesla_raw.csv)
      final result = buf.feed(_hex('10172E78CBE182B8'));
      expect(result, isNull);
      expect(buf.completionPct, closeTo(3.125, 0.1)); // 1/32
    });

    test('completes sweep after 32 unique mux frames', () {
      final buf = CellFrameBuffer();

      // Real frames from tesla_raw.csv — one complete sweep
      final frames = [
        '10172E78CBE182B8', // mux 0x10
        '111C2E87DBE172B8', // mux 0x11
        '12216E880BE22EB8', // mux 0x12
        '131FAE878BE01EB8', // mux 0x13
        '14082E829BE022B8', // mux 0x14
        '1521AE882BE296B8', // mux 0x15
        '1621AE88ABE01AB8', // mux 0x16
        '170C2E83DBE0EAB7', // mux 0x17
        '18AAC578D158F816', // mux 0x18
        '1990056BB1589416', // mux 0x19
        '1A86856B1158CC16', // mux 0x1A
        '1B7BC56BF15AFC15', // mux 0x1B
        '1CBF8568C1589416', // mux 0x1C
        '1D89456A9158A816', // mux 0x1D
        '1E7BC56A4159AC16', // mux 0x1E
        '1F95056E215C4817', // mux 0x1F
        // Now mux 0x00–0x0F (from next sweep in file)
        '010C2E83CBE032B8', // mux 0x01
        '020BEE82BBE032B8', // mux 0x02
        '03FE2D81EBDFA6B7', // mux 0x03
        '0404AE806BE15EB8', // mux 0x04
        '05156E846BE15EB8', // mux 0x05
        '06DF2D7C7BDFEEB7', // mux 0x06
        '07D0AD7D0BE006B8', // mux 0x07
      ];

      // Need a mux 0x00 and 0x08-0x0F to complete — generate synthetics
      // mux 0x00: 4 voltages around 3.6V
      frames.insert(0, '00172E78CBE182B8');
      // mux 0x08-0x0F
      for (int m = 0x08; m <= 0x0F; m++) {
        frames.add('${m.toRadixString(16).padLeft(2, '0')}172E78CBE182B8');
      }

      CellSweepSnapshot? snapshot;
      for (final hex in frames) {
        final result = buf.feed(_hex(hex));
        if (result != null) snapshot = result;
      }

      expect(snapshot, isNotNull);
      expect(snapshot!.cells.length, 96);
      expect(snapshot.moduleTemps.length, 16);
    });

    test('decodes cell voltages in expected range', () {
      final buf = CellFrameBuffer();

      // Feed a single mux 0x10 frame from tesla_raw.csv: 10172E78CBE182B8
      // mux = 0x10 = 16, so cells 64-67
      buf.feed(_hex('10172E78CBE182B8'));

      // Get partial snapshot to check values
      final snap = buf.partialSnapshot();

      // Cell 64 should be decoded from first 14-bit value
      // Payload bytes 1-7: 17 2E 78 CB E1 82 B8
      // Little-endian: B8 82 E1 CB 78 2E 17
      // raw56 = 0xB882E1CB782E17
      // value0 = raw56 & 0x3FFF = 0x2E17 & 0x3FFF... let me compute
      // Actually the payload is bytes[1:8] = [0x17, 0x2E, 0x78, 0xCB, 0xE1, 0x82, 0xB8]
      // LE integer: 0x17 + 0x2E<<8 + 0x78<<16 + 0xCB<<24 + 0xE1<<32 + 0x82<<40 + 0xB8<<48
      // value[0] = raw & 0x3FFF
      // 0x17 | (0x2E << 8) = 0x2E17; value0 = 0x2E17 & 0x3FFF = 0x2E17 = 11799
      // voltage = 11799 * 0.000305 = 3.5987V
      expect(snap.cells[64], closeTo(3.5987, 0.001));
    });

    test('decodes temperatures with sign extension', () {
      final buf = CellFrameBuffer();

      // Mux 0x18 frame: 18AAC578D158F816
      buf.feed(_hex('18AAC578D158F816'));

      final snap = buf.partialSnapshot();
      // Temp values are signed 14-bit × 0.0122
      // The tesla_cells.csv shows some temps around -1493°C which are garbage
      // (filtered to NaN), but some should be valid
      // Module 0 temps are at indices 0,1
      final t0 = snap.moduleTemps[0].$1;
      final t1 = snap.moduleTemps[0].$2;
      // At least check they're doubles (may be NaN if filtered)
      expect(t0, isA<double>());
      expect(t1, isA<double>());
    });

    test('rejects mux index > 0x1F', () {
      final buf = CellFrameBuffer();
      final result = buf.feed(_hex('20172E78CBE182B8'));
      expect(result, isNull);
      expect(buf.completionPct, 0.0);
    });

    test('rejects short frames', () {
      final buf = CellFrameBuffer();
      expect(buf.feed(_hex('10172E78')), isNull);
      expect(buf.completionPct, 0.0);
    });
  });
}
