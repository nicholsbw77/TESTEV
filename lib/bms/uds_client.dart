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

    // ELM init. We stay in CAN auto-format mode (default) — the ELM builds
    // the ISO-TP single/first/consecutive frames from the raw UDS bytes we
    // give it, and reassembles multi-frame responses back to a flat payload.
    // That works uniformly across the OBDLink STN and older ELM clones
    // (including WiCAN's v1.3a emulator which rejects ATCAF0 / ATAL).
    await _at('ATZ',   timeoutMs: 2500);
    await _at('ATE0');
    await _at('ATL0');
    await _at('ATH1');   // headers on: response lines start "612 …"
    await _at('ATS1');   // spaces on for legibility
    await _at('ATSP6');  // ISO 15765-4 CAN 11-bit @ 500 kbps
    await _at('ATST FF');// max receive timeout (~1s) — Tesla BMS is unhurried
  }

  /// Configure the request header and ISO-TP flow-control for a given
  /// request/response CAN ID pair. Call this whenever the routine's CAN ID
  /// changes (e.g. between 0x602 and 0x601 routines).
  Future<void> setSession({required int reqCanId}) async {
    final hex = _canIdHex(reqCanId);
    await _at('ATSH $hex');       // request header
    await _at('ATFCSH $hex');     // flow-control sends use same header
    await _at('ATFCSD 30 00 00'); // FC data: CTS, block=0, ST=0
    await _at('ATFCSM 1');        // FC mode 1: user-defined FC
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
    final hex = udsBytes
        .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
    return sendHex(hex, expect: expect, timeout: timeout);
  }

  /// Positive-response helper: sends [hex] and returns true iff the reply
  /// contains [expect] before the timeout, false on ELM prompt without a
  /// match, timeout, or a UDS negative response (`7F …`).
  Future<bool> sendExpect(
    String hex,
    String expect, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final reply = await sendHex(hex, expect: expect, timeout: timeout);
      final up = reply.toUpperCase();
      // Negative response service byte 0x7F followed by the requested
      // service id echoes up as "7F XX YY" and means the ECU rejected the
      // request — never confuse that with a positive match.
      if (RegExp(r'\b7F\s').hasMatch(up)) return false;
      return up.contains(expect.toUpperCase());
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

  Future<void> close() async {
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
