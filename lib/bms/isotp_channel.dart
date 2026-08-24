import 'dart:async';
import 'dart:collection';

import '../can/can_frame.dart';
import '../can/slcan_adapter.dart';

/// ISO 15765-2 (ISO-TP) transport over a raw CAN bus (SLCAN).
///
/// Line-for-line port of the reference `can_reader/isotp.py` in the Tesla
/// bench GUI Python code — the exact layer that produces a successful
/// SecurityAccess unlock against the 2013 Model S BMS.
///
/// Frame types (byte 0 nibble):
///   0x0 — Single Frame:  [len | data...]                     (≤7 UDS bytes)
///   0x1 — First Frame:   [0x10|lenHi, lenLo, data0..5]
///   0x2 — Consecutive:   [0x20|sn, data0..6]                 (sn 1..15, wraps)
///   0x3 — Flow Control:  [0x30|fs, bs, stmin]                (fs 0=CTS)
///
/// Frames are always padded to 8 bytes with 0x00 (matches ISO 15765-4 and
/// what Tesla Toolbox sends).
class IsoTpChannel {
  final SlcanAdapter adapter;
  final int txId;
  final int rxId;

  /// P2 — max wait for the first response frame.
  Duration p2Timeout;

  /// P2* — extended wait after a `7F XX 78` "response pending" NRC.
  Duration p2StarTimeout;

  /// Max wait between consecutive frames of a multi-frame reply.
  final Duration cfTimeout;

  /// Flow-control block size we send back to the ECU. 0 = send them all.
  final int fcBlockSize;

  /// Flow-control STmin (ms) we send back to the ECU. 0 = no min gap.
  final int fcStmin;

  StreamSubscription<CanFrame>? _sub;
  final Queue<CanFrame> _rxQueue = Queue<CanFrame>();
  Completer<void>? _rxNotify;

  IsoTpChannel(
    this.adapter, {
    required this.txId,
    required this.rxId,
    this.p2Timeout = const Duration(seconds: 2),
    this.p2StarTimeout = const Duration(seconds: 5),
    this.cfTimeout = const Duration(milliseconds: 250),
    this.fcBlockSize = 0,
    this.fcStmin = 0,
  });

  /// Start consuming frames from the adapter into the internal RX queue.
  /// Only frames whose CAN ID matches [rxId] are kept.
  void open() {
    _sub = adapter.frameStream.listen((frame) {
      if (frame.id != rxId) return;
      _rxQueue.add(frame);
      final n = _rxNotify;
      if (n != null && !n.isCompleted) {
        _rxNotify = null;
        n.complete();
      }
    });
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _rxQueue.clear();
    final n = _rxNotify;
    if (n != null && !n.isCompleted) {
      _rxNotify = null;
      n.completeError(StateError('IsoTpChannel closed'));
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Send a UDS payload and return the response payload (service id + data).
  /// Throws [IsoTpTimeout], [IsoTpNegativeResponse], or [IsoTpError] on
  /// failure. Mirrors Python `ISOTPChannel.send_recv`.
  Future<List<int>> sendRecv(List<int> data) async {
    // Drain any stale bus chatter that arrived between requests so we
    // don't misinterpret it as our reply.
    _rxQueue.clear();
    await _send(data);
    return _recv(deadline: DateTime.now().add(p2Timeout));
  }

  /// Fire-and-forget send (no reply awaited). Used for TesterPresent with
  /// the suppress-positive-response bit set.
  Future<void> sendNoReply(List<int> data) async {
    await _send(data);
  }

  // ── Send ───────────────────────────────────────────────────────────────────

  Future<void> _send(List<int> data) async {
    if (data.length <= 7) {
      _sendSingleFrame(data);
    } else {
      await _sendMultiFrame(data);
    }
  }

  void _sendSingleFrame(List<int> data) {
    _tx(<int>[data.length, ...data]);
  }

  Future<void> _sendMultiFrame(List<int> data) async {
    final length = data.length;
    // First frame: 0x10|lenHi, lenLo, data[0..5]
    final ff = <int>[
      0x10 | ((length >> 8) & 0x0F),
      length & 0xFF,
      ...data.sublist(0, 6),
    ];
    _tx(ff);

    // Wait for Flow Control from the ECU.
    final fc = await _recvFc();
    int bs = fc[1];
    int stmin = fc[2];

    // Consecutive frames.
    int sn = 1;
    int offset = 6;
    int blockCount = 0;
    while (offset < length) {
      final chunk = data.sublist(
          offset, offset + 7 > length ? length : offset + 7);
      _tx(<int>[0x20 | (sn & 0x0F), ...chunk]);
      offset += 7;
      sn = (sn + 1) & 0x0F;
      blockCount += 1;

      if (stmin > 0) {
        await Future.delayed(Duration(milliseconds: stmin));
      }

      if (bs > 0 && blockCount >= bs) {
        final nextFc = await _recvFc();
        bs = nextFc[1];
        stmin = nextFc[2];
        blockCount = 0;
      }
    }
  }

  Future<List<int>> _recvFc() async {
    final deadline = DateTime.now().add(cfTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final frame = await _awaitFrame(deadline);
      if (frame == null) break;
      if (frame.data.isEmpty) continue;
      if ((frame.data[0] >> 4) == 0x3) {
        if (frame.data.length < 3) {
          return [frame.data[0], 0, 0];
        }
        return frame.data;
      }
      // Not a FC — drop and keep looking.
    }
    throw IsoTpTimeout('Timeout waiting for Flow Control frame');
  }

  // ── Receive ────────────────────────────────────────────────────────────────

  Future<List<int>> _recv({required DateTime deadline}) async {
    while (DateTime.now().isBefore(deadline)) {
      final frame = await _awaitFrame(deadline);
      if (frame == null) break;
      final d = frame.data;
      if (d.isEmpty) continue;
      final frameType = (d[0] >> 4) & 0x0F;

      if (frameType == 0x0) {
        // Single frame.
        final length = d[0] & 0x0F;
        final payload = d.sublist(1, 1 + length);
        return _checkResponse(payload);
      }

      if (frameType == 0x1) {
        // First frame — send FC, then collect CFs.
        final length = ((d[0] & 0x0F) << 8) | d[1];
        final payload = <int>[...d.sublist(2)];
        _sendFlowControl();

        int expectedSn = 1;
        var cfDeadline = DateTime.now().add(cfTimeout);
        while (payload.length < length) {
          if (DateTime.now().isAfter(cfDeadline)) {
            throw IsoTpTimeout('Timeout waiting for consecutive frame');
          }
          final cfFrame = await _awaitFrame(cfDeadline);
          if (cfFrame == null) continue;
          final cf = cfFrame.data;
          if (cf.isEmpty || ((cf[0] >> 4) & 0x0F) != 0x2) continue;
          final sn = cf[0] & 0x0F;
          if (sn != expectedSn) {
            throw IsoTpError(
                'Sequence error: expected SN $expectedSn, got $sn');
          }
          payload.addAll(cf.sublist(1));
          expectedSn = (expectedSn + 1) & 0x0F;
          cfDeadline = DateTime.now().add(cfTimeout);
        }
        return _checkResponse(payload.sublist(0, length));
      }

      // Anything else (stray FC, etc.) — ignore.
    }
    throw IsoTpTimeout(
        'No response from 0x${rxId.toRadixString(16).toUpperCase()} '
        'within ${p2Timeout.inMilliseconds}ms');
  }

  void _sendFlowControl() {
    _tx([0x30, fcBlockSize, fcStmin]);
  }

  Future<List<int>> _checkResponse(List<int> payload) async {
    if (payload.length >= 3 && payload[0] == 0x7F) {
      final serviceId = payload[1];
      final nrc = payload[2];
      if (nrc == 0x78) {
        // ISO 14229 P2* — the ECU is processing; keep listening for the
        // real reply within the extended window.
        return _recv(deadline: DateTime.now().add(p2StarTimeout));
      }
      throw IsoTpNegativeResponse(serviceId, nrc);
    }
    return payload;
  }

  // ── Low-level RX helpers ───────────────────────────────────────────────────

  Future<CanFrame?> _awaitFrame(DateTime deadline) async {
    if (_rxQueue.isNotEmpty) {
      return _rxQueue.removeFirst();
    }
    final wait = deadline.difference(DateTime.now());
    if (wait <= Duration.zero) return null;
    _rxNotify = Completer<void>();
    try {
      await _rxNotify!.future.timeout(wait);
    } on TimeoutException {
      _rxNotify = null;
      return null;
    }
    if (_rxQueue.isNotEmpty) {
      return _rxQueue.removeFirst();
    }
    return null;
  }

  // ── TX helper ──────────────────────────────────────────────────────────────

  void _tx(List<int> data) {
    // Pad to 8 bytes with 0x00 (ISO 15765-4 / Tesla Toolbox).
    final padded = List<int>.filled(8, 0);
    for (var i = 0; i < data.length && i < 8; i++) {
      padded[i] = data[i] & 0xFF;
    }
    adapter.sendFrame(txId, padded);
  }
}

// ── Exceptions ──────────────────────────────────────────────────────────────

class IsoTpError implements Exception {
  final String message;
  IsoTpError(this.message);
  @override
  String toString() => 'IsoTpError: $message';
}

class IsoTpTimeout extends IsoTpError {
  IsoTpTimeout(super.message);
}

class IsoTpNegativeResponse extends IsoTpError {
  final int serviceId;
  final int nrc;
  IsoTpNegativeResponse(this.serviceId, this.nrc)
      : super('NRC 0x${nrc.toRadixString(16).padLeft(2, '0').toUpperCase()} '
            '(${nrcDescription(nrc)}) for service '
            '0x${serviceId.toRadixString(16).padLeft(2, '0').toUpperCase()}');
}

String nrcDescription(int nrc) => _nrcDescriptions[nrc] ?? 'unknown NRC';

const _nrcDescriptions = <int, String>{
  0x10: 'general reject',
  0x11: 'service not supported',
  0x12: 'sub-function not supported',
  0x13: 'incorrect message length',
  0x14: 'response too long',
  0x21: 'busy — repeat request',
  0x22: 'conditions not correct',
  0x24: 'request sequence error',
  0x25: 'no response from sub-net component',
  0x26: 'failure prevents execution',
  0x31: 'request out of range',
  0x33: 'security access denied',
  0x35: 'invalid key',
  0x36: 'exceeded number of attempts',
  0x37: 'required time delay not expired',
  0x70: 'upload/download not accepted',
  0x71: 'transfer data suspended',
  0x72: 'general programming failure',
  0x73: 'wrong block sequence counter',
  0x78: 'response pending',
  0x7E: 'sub-function not supported in active session',
  0x7F: 'service not supported in active session',
};
