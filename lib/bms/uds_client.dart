import 'dart:async';
import 'dart:convert';

import '../can/elm327_base.dart';

/// Request/response layer over an already-open `Elm327Base` transport.
///
/// We do NOT reuse `Elm327Base.connect()` (which starts monitor mode with
/// STFAP filters + ATMA). Instead we `openTransport()` on the adapter, then
/// this client runs a UDS-friendly init:
///
///   ATZ ATE0 ATL0 ATH1 ATS1 ATAL ATCAF0 ATSP6
///
/// After [initialize], call [setSession] with the request/response CAN ID
/// pair (Tesla BMS: 0x602/0x612 or 0x601/0x611), then use [sendHex] for
/// individual UDS messages.
///
/// The client owns the sole subscription to `adapter.inputStream()` for its
/// lifetime — don't share the transport with anything else.
class UdsClient {
  final Elm327Base adapter;
  final void Function(String line)? onLog;

  StreamSubscription<List<int>>? _sub;
  String _buffer = '';
  Completer<String>? _pending;
  String? _expectToken;    // uppercase token to match
  Timer? _timeoutTimer;
  Timer? _keepAliveTimer;

  /// true if the adapter accepted ATCAF0 (real ELM/STN — we frame ISO-TP
  /// ourselves and the ELM auto-handles flow control on receive).
  /// false if it rejected ATCAF0 with '?' (WiCAN's v1.3a emulator — we
  /// have to send just the UDS service bytes and let the ELM build the
  /// ISO-TP for us, which unfortunately breaks manual multi-frame sends).
  bool manualFraming = true;

  UdsClient(this.adapter, {this.onLog});

  bool get isOpen => _sub != null;

  /// Open the transport, subscribe to input, and run the UDS-friendly ELM init.
  Future<void> initialize() async {
    if (_sub != null) return;
    await adapter.openTransport();
    _sub = adapter.inputStream().listen(_onData, onError: (e) {
      _log('link error: $e');
      _completeError(e is Object ? e : Exception('$e'));
    }, onDone: () {
      _log('link closed');
      _completeError(StateError('transport closed'));
    });

    // ELM init. We try to enable "manual framing" mode (ATCAF0 + ATAL) —
    // that's T-Clear's proven-working sequence and reliably lets us drive
    // multi-frame SendKey ourselves. If the adapter rejects ATCAF0 with
    // '?' (WiCAN's v1.3a emulator does), we fall back to CAF-on mode where
    // the ELM builds ISO-TP for us — single-frame commands still work,
    // multi-frame SendKey may not.
    await _at('ATZ',   timeoutMs: 2500);
    await _at('ATE0');
    await _at('ATL0');
    await _at('ATH1');   // headers on: response lines start "612 …"
    await _at('ATS1');   // spaces on for legibility
    await _at('ATAL');   // allow long messages (needed for ISO-TP >7 bytes)
    final cafReply = await _at('ATCAF0');
    manualFraming = !cafReply.contains('?');
    if (!manualFraming) {
      _log('!! adapter rejected ATCAF0 — falling back to CAF-on (multi-frame '
          'SendKey may not work on this adapter)');
    }
    await _at('ATSP6');    // ISO 15765-4 CAN 11-bit @ 500 kbps
    await _at('ATST FF');  // max receive timeout (~1s)
    await _at('ATAT1');    // adaptive timing on — give slow ECUs slack
  }

  /// Configure the request header, the response-address filter, and the
  /// ISO-TP flow-control for a given request/response CAN ID pair. Call
  /// this whenever the routine's CAN ID changes (e.g. between 0x602 and
  /// 0x601 routines).
  ///
  /// [rspCanId] defaults to `reqCanId + 0x10` — the Tesla convention on
  /// the 2013-era BMS (0x602 → 0x612, 0x601 → 0x611). Pass it explicitly
  /// for anything that doesn't follow that offset.
  ///
  /// **`ATCRA <rsp>` is critical**: without it, non-OBD-II responses
  /// (like 0x612) are dropped by strict-filter ELM firmwares (WiCAN's
  /// v1.3a emulator is one) and the request comes back as `NO DATA`
  /// even though the ECU replied on the bus. The reference Python paths
  /// (`wican_uds.py`, `can_reader/isotp.py`) sidestep this by bypassing
  /// the ELM entirely — raw slcan / python-can sees every frame and
  /// filters in software. We can't; through the ELM, we must ask.
  ///
  /// Flow-control mode is set to 0 (fully automatic) so the ELM picks
  /// the correct FC header and data itself (`30 00 00` by default,
  /// matching what the reference Python `_send_flow_control()` sends).
  /// Manual FC via `ATFCSM 1` / `2` proved flaky on multi-frame RX for
  /// non-OBD UDS services on this OBDLink firmware.
  Future<void> setSession({required int reqCanId, int? rspCanId}) async {
    final txHex = _canIdHex(reqCanId);
    final rxHex = _canIdHex(rspCanId ?? (reqCanId + 0x10));
    await _at('ATSH $txHex');     // TX header
    await _at('ATCRA $rxHex');    // filter incoming to just this response ID
    await _at('ATFCSM 0');        // FC mode 0: fully automatic
  }

  /// Send an ELM/AT command; wait for the `>` prompt.
  Future<String> _at(String cmd, {int timeoutMs = 800}) {
    return _sendAndWait(cmd,
        expect: null, timeout: Duration(milliseconds: timeoutMs));
  }

  /// Send a raw UDS hex payload (e.g. `'02 10 03'`). Returns the raw ELM
  /// response text (may contain multiple `\r`-delimited lines and the `>`).
  ///
  /// If [expect] is provided, resolves as soon as the response contains that
  /// substring (case-insensitive); otherwise waits for the `>` prompt.
  Future<String> sendHex(
    String hex, {
    String? expect,
    Duration timeout = const Duration(seconds: 3),
  }) {
    return _sendAndWait(hex.toUpperCase(), expect: expect, timeout: timeout);
  }

  /// Send a UDS payload as UDS-service-bytes only (no ISO-TP length prefix,
  /// no padding). With CAF-on the ELM builds the frame; single/multi-frame
  /// alike are handled by the adapter.
  Future<String> sendUds(
    List<int> udsBytes, {
    String? expect,
    Duration timeout = const Duration(seconds: 3),
  }) {
    final hex = _hex(udsBytes);
    return sendHex(hex, expect: expect, timeout: timeout);
  }

  /// Send a single-frame UDS request (≤7 UDS bytes).
  ///
  /// In [manualFraming] mode we prepend the ISO-TP length byte and pad to
  /// 8 bytes (T-Clear's exact wire form). Otherwise we send just the UDS
  /// bytes and let the ELM build the frame.
  Future<String> sendUdsSingleFrame(
    List<int> udsBytes, {
    String? expect,
    Duration timeout = const Duration(seconds: 3),
  }) {
    assert(udsBytes.length <= 7, 'single frame carries at most 7 UDS bytes');
    final hex = manualFraming
        ? _hex([udsBytes.length, ...udsBytes, ...List.filled(7 - udsBytes.length, 0)])
        : _hex(udsBytes);
    return sendHex(hex, expect: expect, timeout: timeout);
  }

  Future<bool> sendUdsSingleFrameExpect(
    List<int> udsBytes,
    String expect, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      var reply = await sendUdsSingleFrame(
          udsBytes, expect: expect, timeout: timeout);
      if (_extractNrc(reply) == 0x78) {
        _log('  ↻ NRC 0x78 (response pending) — waiting P2* (5s)…');
        try {
          final more = await _waitFor(expect: expect,
              timeout: const Duration(seconds: 5));
          reply = reply + more;
        } catch (_) {}
      }
      final nrc = _extractNrc(reply);
      if (nrc != null && nrc != 0x78) {
        _log('  ✗ Negative response NRC 0x${nrc.toRadixString(16).toUpperCase().padLeft(2, '0')}'
            ' (${_nrcDescription(nrc)})');
        return false;
      }
      return reply.toUpperCase().contains(expect.toUpperCase());
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Send a multi-frame UDS request (>7 UDS bytes). In [manualFraming]
  /// mode we emit the ISO-TP First Frame and Consecutive Frames on the
  /// wire ourselves (matching T-Clear's SendKey sequence), with small
  /// sleeps between and the caller's [expect] token matched against the
  /// reply to the FINAL frame. In CAF-on mode we hand the whole payload
  /// to the ELM and hope it auto-fragments (some adapters won't).
  Future<bool> sendUdsMultiFrameExpect(
    List<int> udsBytes,
    String expect, {
    Duration timeout = const Duration(seconds: 4),
    Duration interFrameDelay = const Duration(milliseconds: 500),
  }) async {
    try {
      if (!manualFraming) {
        var reply = await sendUds(udsBytes, expect: expect, timeout: timeout);
        if (_extractNrc(reply) == 0x78) {
          _log('  ↻ NRC 0x78 (response pending) — waiting P2* (5s)…');
          try {
            final more = await _waitFor(expect: expect,
                timeout: const Duration(seconds: 5));
            reply = reply + more;
          } catch (_) {}
        }
        final nrc = _extractNrc(reply);
        if (nrc != null && nrc != 0x78) {
          _log('  ✗ Negative response NRC 0x${nrc.toRadixString(16).toUpperCase().padLeft(2, '0')}'
              ' (${_nrcDescription(nrc)})');
          return false;
        }
        return reply.toUpperCase().contains(expect.toUpperCase());
      }
      // Manual framing.
      // First Frame: 10 <lenLow>  <first 6 bytes of UDS>
      //   (length field is 12 bits: high nibble in low nibble of first byte)
      final total = udsBytes.length;
      if (total > 0xFFF) throw ArgumentError('payload too long for single ISO-TP');
      final ff = <int>[
        0x10 | ((total >> 8) & 0x0F),
        total & 0xFF,
        ...udsBytes.sublist(0, 6),
      ];
      // The ECU should reply with a Flow Control 30 XX YY — we don't need
      // to parse it (ATFCSM lets the ELM auto-generate our FC on receive,
      // but the ECU's FC to us is just informational). Give the ELM a
      // moment to see it.
      await sendHex(_hex(ff), timeout: const Duration(seconds: 1))
          .catchError((_) => '');
      await Future.delayed(interFrameDelay);
      // Consecutive Frames: 21, 22, 23, ... (mod 16) with 7 UDS bytes each.
      int idx = 6;
      int sn = 1;
      while (idx < total) {
        final chunk = <int>[];
        for (int k = 0; k < 7; k++) {
          chunk.add(idx < total ? udsBytes[idx++] : 0);
        }
        final cf = [0x20 | (sn & 0x0F), ...chunk];
        sn++;
        final isLast = idx >= total;
        if (isLast) {
          var reply = await sendHex(_hex(cf), expect: expect, timeout: timeout);
          if (_extractNrc(reply) == 0x78) {
            _log('  ↻ NRC 0x78 (response pending) — waiting P2* (5s)…');
            try {
              final more = await _waitFor(expect: expect,
                  timeout: const Duration(seconds: 5));
              reply = reply + more;
            } catch (_) {}
          }
          final nrc = _extractNrc(reply);
          if (nrc != null && nrc != 0x78) {
            _log('  ✗ Negative response NRC 0x${nrc.toRadixString(16).toUpperCase().padLeft(2, '0')}'
                ' (${_nrcDescription(nrc)})');
            return false;
          }
          return reply.toUpperCase().contains(expect.toUpperCase());
        }
        await sendHex(_hex(cf), timeout: const Duration(seconds: 1))
            .catchError((_) => '');
        await Future.delayed(interFrameDelay);
      }
      return false; // shouldn't reach here
    } on TimeoutException {
      return false;
    }
  }

  static String _hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join(' ');

  /// Wait for additional data on the input stream (no send). Used to
  /// extend the P2 window after a 0x78 "response pending" NRC.
  Future<String> _waitFor({String? expect, required Duration timeout}) async {
    if (_pending != null) {
      throw StateError('UdsClient is busy');
    }
    _buffer = '';
    _expectToken = expect?.toUpperCase();
    _pending = Completer<String>();
    _timeoutTimer = Timer(timeout, () {
      if (!(_pending?.isCompleted ?? true)) {
        _pending!.completeError(
            TimeoutException('waitFor "$expect" expired', timeout));
      }
    });
    try {
      final reply = await _pending!.future;
      _logMultiline(reply);
      return reply;
    } finally {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      _pending = null;
      _expectToken = null;
    }
  }

  /// Extract the UDS negative-response NRC from an ELM reply, if present.
  /// A negative response comes back as `7F <svc> <nrc>` (single-frame
  /// service `7F`). With ATH1 the reply also has the CAN ID prefix.
  int? _extractNrc(String reply) {
    final up = reply.toUpperCase();
    // Match "7F XX YY" as three hex bytes, service byte 7F followed by
    // the echoed service id and the NRC. Anchor on a whitespace boundary
    // so an incidental "7F" inside a data payload doesn't false-match.
    final m = RegExp(r'(?:^|\s)7F\s+[0-9A-F]{2}\s+([0-9A-F]{2})\b').firstMatch(up);
    if (m == null) return null;
    return int.tryParse(m.group(1)!, radix: 16);
  }

  /// Terse human name for the standard UDS NRCs.
  static String _nrcDescription(int nrc) {
    return _nrcNames[nrc] ?? 'NRC 0x${nrc.toRadixString(16).toUpperCase()}';
  }
  static const _nrcNames = <int, String>{
    0x10: 'general reject',
    0x11: 'service not supported',
    0x12: 'sub-function not supported',
    0x13: 'incorrect message length',
    0x21: 'busy — repeat request',
    0x22: 'conditions not correct',
    0x24: 'request sequence error',
    0x25: 'no response from sub-net component',
    0x31: 'request out of range',
    0x33: 'security access denied',
    0x35: 'invalid key',
    0x36: 'exceeded attempts',
    0x37: 'required time delay not expired',
    0x7E: 'sub-function not supported in this session',
    0x7F: 'service not supported in this session',
  };

  /// Positive-response helper: sends [hex] and returns true iff the reply
  /// contains [expect] before the timeout, false on ELM prompt without a
  /// match, timeout, or a UDS negative response (`7F …`).
  ///
  /// Handles NRC 0x78 ("response pending") the way the reference Python
  /// ISOTPChannel does: waits another 5 s for the real response before
  /// giving up.
  Future<bool> sendExpect(
    String hex,
    String expect, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      var reply = await sendHex(hex, expect: expect, timeout: timeout);
      // Retry the wait once if the ECU says "response pending" (NRC 0x78).
      // We stay on the same request — the ECU will produce a fresh reply.
      if (_extractNrc(reply) == 0x78) {
        _log('  ↻ NRC 0x78 (response pending) — waiting P2* (5s)…');
        try {
          final more = await _waitFor(expect: expect,
              timeout: const Duration(seconds: 5));
          reply = reply + more;
        } catch (_) {}
      }
      final nrc = _extractNrc(reply);
      if (nrc != null && nrc != 0x78) {
        _log('  ✗ Negative response NRC 0x${nrc.toRadixString(16).toUpperCase().padLeft(2, '0')}'
            ' (${_nrcDescription(nrc)})');
        return false;
      }
      return reply.toUpperCase().contains(expect.toUpperCase());
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// UDS-bytes variant of [sendExpect].
  Future<bool> sendUdsExpect(
    List<int> udsBytes,
    String expect, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    final hex = udsBytes
        .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
    return sendExpect(hex, expect, timeout: timeout);
  }

  Future<String> _sendAndWait(
    String cmd, {
    required String? expect,
    required Duration timeout,
  }) async {
    if (_pending != null) {
      throw StateError('UdsClient is busy with another request');
    }
    _buffer = '';
    _expectToken = expect?.toUpperCase();
    _pending = Completer<String>();
    _timeoutTimer = Timer(timeout, () {
      if (!(_pending?.isCompleted ?? true)) {
        _pending!.completeError(
            TimeoutException('no reply to "$cmd"', timeout));
      }
    });
    _log('>>> $cmd');
    adapter.writeBytes(utf8.encode('$cmd\r'));
    try {
      final reply = await _pending!.future;
      _logMultiline(reply);
      return reply;
    } finally {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      _pending = null;
      _expectToken = null;
    }
  }

  void _onData(List<int> data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    final completer = _pending;
    if (completer == null || completer.isCompleted) return;
    final up = _buffer.toUpperCase();
    if (_expectToken != null && up.contains(_expectToken!)) {
      completer.complete(_buffer);
      return;
    }
    // ELM finishes every reply with '>'. If no expect was set (AT command)
    // or if the ELM finished before we saw our token, resolve on the prompt.
    if (up.contains('>')) {
      completer.complete(_buffer);
    }
  }

  void _completeError(Object err) {
    final c = _pending;
    if (c != null && !c.isCompleted) c.completeError(err);
  }

  void _log(String s) => onLog?.call(s);
  void _logMultiline(String reply) {
    for (final line in reply.split(RegExp(r'[\r\n]+'))) {
      final t = line.trim();
      if (t.isEmpty || t == '>') continue;
      _log('<<< $t');
    }
  }

  /// Start sending TesterPresent (`3E 80`, suppress-response-bit set) at
  /// [interval] on the current ATSH header. Tesla BMS drops the session
  /// after ~5 s of silence — with the extended session open you must keep
  /// this heartbeat going or the next real request will get a NRC 0x7F.
  ///
  /// The keepalive queues after any pending real request (via the same
  /// `_sendAndWait` mutex) so it can never collide with a routine send.
  void startKeepAlive({Duration interval = const Duration(milliseconds: 4500)}) {
    stopKeepAlive();
    _keepAliveTimer = Timer.periodic(interval, (_) async {
      if (_pending != null) return; // busy — skip this tick
      try {
        // 3E 80 = TesterPresent with suppress-positive-response bit set,
        // so the ECU sends no reply and we don't have to match one.
        // In manualFraming mode: pad to 8 bytes; otherwise send raw.
        final hex = manualFraming
            ? '02 3E 80 00 00 00 00 00'
            : '3E 80';
        await sendHex(hex, timeout: const Duration(milliseconds: 800))
            .catchError((_) => '');
      } catch (_) {}
    });
  }

  void stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  Future<void> close() async {
    stopKeepAlive();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _completeError(StateError('closed'));
    await _sub?.cancel();
    _sub = null;
    try {
      await adapter.closeTransport();
    } catch (_) {}
  }

  static String _canIdHex(int id) =>
      id.toRadixString(16).toUpperCase().padLeft(3, '0');
}

/// Render a byte list as `'04 31 01 04 0A 00 00 00'` — used to build the
/// hex string for [UdsClient.sendHex].
String bytesToElmHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
