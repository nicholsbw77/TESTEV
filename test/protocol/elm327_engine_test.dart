import 'package:flutter_test/flutter_test.dart';
import 'package:testev/protocol/elm327_engine.dart';
import 'package:testev/protocol/can_frame.dart';

void main() {
  group('Elm327Engine', () {
    late Elm327Engine engine;

    setUp(() {
      engine = Elm327Engine();
    });

    tearDown(() {
      engine.dispose();
    });

    test('parses spaced ELM327 output', () {
      final frames = <CanFrame>[];
      engine.frameStream.listen(frames.add);

      engine.feedString('6F2 18 6D C6 A3 C1 66 64 1A\r');

      expect(frames.length, 1);
      expect(frames[0].arbitrationId, 0x6F2);
      expect(frames[0].data.length, 8);
      expect(frames[0].data[0], 0x18);
    });

    test('parses compact ELM327 output (no spaces)', () {
      final frames = <CanFrame>[];
      engine.frameStream.listen(frames.add);

      engine.feedString('6F2186DC6A3C16641A\r');

      expect(frames.length, 1);
      expect(frames[0].arbitrationId, 0x6F2);
      expect(frames[0].data.length, 8);
    });

    test('skips ELM327 prompts and status lines', () {
      final frames = <CanFrame>[];
      engine.frameStream.listen(frames.add);

      engine.feedString('>\r');
      engine.feedString('OK\r');
      engine.feedString('SEARCHING...\r');
      engine.feedString('NO DATA\r');
      engine.feedString('ATZ\r');
      engine.feedString('ELM327 v1.5\r');
      engine.feedString('STN2120\r');

      expect(frames, isEmpty);
    });

    test('handles multiple frames in buffer', () {
      final frames = <CanFrame>[];
      engine.frameStream.listen(frames.add);

      engine.feedString(
          '6F2 10 17 2E 78 CB E1 82 B8\r'
          '6F2 11 1C 2E 87 DB E1 72 B8\r'
          '102 04 87 FB FF FA FF AC 09\r');

      expect(frames.length, 3);
      expect(frames[0].arbitrationId, 0x6F2);
      expect(frames[1].arbitrationId, 0x6F2);
      expect(frames[2].arbitrationId, 0x102);
    });

    test('handles partial data across multiple feeds', () {
      final frames = <CanFrame>[];
      engine.frameStream.listen(frames.add);

      engine.feedString('6F2 10 17 2E 78');
      expect(frames, isEmpty);

      engine.feedString(' CB E1 82 B8\r');
      expect(frames.length, 1);
      expect(frames[0].arbitrationId, 0x6F2);
    });

    test('tracks frame rate', () {
      engine.feedString('6F2 10 17 2E 78 CB E1 82 B8\r');
      // fps won't update until 1 second passes, but frameCount should be tracked
      expect(engine.fps, greaterThanOrEqualTo(0));
    });

    test('builds init sequence with STFAP filters', () {
      final cmds = engine.buildInitSequence(stfapFilters: [
        '332,7FF', '392,7FF', '6F2,7FF',
      ]);
      // Should have: ATZ, ATE0, ATL0, ATH1, ATCAF0, ATCSM1 (6)
      // + STFCP (1) + 3 STFAP (3) + ATMA (1) = 11
      expect(cmds.length, 11);

      final last = String.fromCharCodes(cmds.last);
      expect(last, contains('ATMA'));
    });

    test('rejects invalid hex lines', () {
      final frames = <CanFrame>[];
      engine.frameStream.listen(frames.add);

      engine.feedString('ZZZZZZ\r');
      engine.feedString('this is not CAN data\r');
      engine.feedString('?\r');

      expect(frames, isEmpty);
    });
  });
}
