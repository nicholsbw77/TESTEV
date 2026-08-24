import 'dart:async';

import '../can/slcan_adapter.dart';
import 'isotp_channel.dart';

/// UDS (ISO 14229) client for the Tesla Model S BMS.
///
/// Port of the working ISO-TP path in `can_reader/uds.py`. Sits on top of
/// [IsoTpChannel] (raw-CAN via SLCAN), NOT an ELM327 — ELM adapters
/// physically cannot do UDS on this pack (Python explicitly rejects the
/// send call for that path).
///
/// Confirmed address pair (2013 Model S BMS): TX 0x602, RX 0x612.
/// Confirmed key algorithm: `key[i] = seed[i] XOR 0x35`.
///
/// Typical usage:
///
///     final client = BmsUdsClient(adapter);
///     client.open();
///     await client.startSession(0x03);
///     await client.unlockSecurity();       // XOR-0x35, seed comes from BMS
///     client.startKeepAlive();             // 3E 80 every 4.5s
///     await client.runRoutine(0x0406);     // returns RoutineResult
///     await client.close();
class BmsUdsClient {
  final SlcanAdapter adapter;
  final int txId;
  final int rxId;
  final void Function(String line)? onLog;

  /// Tesla Model S BMS security algorithm: `key[i] = seed[i] XOR 0x35`.
  /// Overridable so callers can inject a different algorithm if the pack
  /// firmware uses one.
  final List<int> Function(List<int> seed) seedToKey;

  IsoTpChannel? _ch;
  Timer? _keepAliveTimer;
  bool _busy = false;

  int _sessionType = 0;
  bool _securityUnlocked = false;

  BmsUdsClient(
    this.adapter, {
    this.txId = 0x602,
    this.rxId = 0x612,
    this.onLog,
    List<int> Function(List<int> seed)? seedToKey,
  }) : seedToKey = seedToKey ?? _defaultSeedToKey;

  int get sessionType => _sessionType;
  bool get securityUnlocked => _securityUnlocked;

  void open() {
    _ch = IsoTpChannel(adapter, txId: txId, rxId: rxId)..open();
  }

  Future<void> close() async {
    stopKeepAlive();
    await _ch?.close();
    _ch = null;
  }

  // ── Session ────────────────────────────────────────────────────────────────

  /// UDS $10 DiagnosticSessionControl. Returns true on positive response.
  /// Tries the requested [sessionId] with a short retry (matches Python's
  /// three-attempt sequence) since the first `10 03` after power-up can
  /// take ~3 s while the BMS wakes its diagnostic stack.
  Future<bool> startSession(int sessionId, {int retries = 2}) async {
    _log('>>> 10 ${_h(sessionId)}   (DiagnosticSessionControl)');
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final reply = await _send([0x10, sessionId]);
        if (reply.isNotEmpty && reply[0] == 0x50) {
          _sessionType = sessionId;
          _log('<<< ${_hexList(reply)}    (session opened)');
          return true;
        }
        _log('<<< ${_hexList(reply)}    (unexpected reply)');
      } on IsoTpTimeout catch (e) {
        _log('!! timeout: ${e.message}');
      } on IsoTpNegativeResponse catch (e) {
        _log('!! ${e.message}');
        return false; // negative response — retrying won't help
      } catch (e) {
        _log('!! error: $e');
      }
    }
    return false;
  }

  // ── SecurityAccess ─────────────────────────────────────────────────────────

  /// UDS $27 SecurityAccess — request seed at [level] (default 0x05),
  /// derive key via [seedToKey], send key at level+1. Returns true iff
  /// the ECU accepts the key.
  Future<bool> unlockSecurity({int level = 0x05}) async {
    _log('>>> 27 ${_h(level)}   (SecurityAccess RequestSeed L$level)');
    List<int> reply;
    try {
      reply = await _send([0x27, level]);
    } on IsoTpNegativeResponse catch (e) {
      _log('!! ${e.message}');
      return false;
    } on IsoTpTimeout catch (e) {
      _log('!! seed timeout: ${e.message}');
      return false;
    }
    if (reply.length < 3 || reply[0] != 0x67 || reply[1] != level) {
      _log('<<< ${_hexList(reply)}    (unexpected seed reply)');
      return false;
    }
    final seed = reply.sublist(2);
    final key = seedToKey(seed);
    _log('<<< seed=${_hexList(seed)}');
    _log('    key =${_hexList(key)}  (XOR 0x35)');

    _log('>>> 27 ${_h(level + 1)} <key…>   (SecurityAccess SendKey)');
    List<int> reply2;
    try {
      reply2 = await _send([0x27, level + 1, ...key]);
    } on IsoTpNegativeResponse catch (e) {
      _log('!! ${e.message}');
      return false;
    } on IsoTpTimeout catch (e) {
      _log('!! sendkey timeout: ${e.message}');
      return false;
    }
    if (reply2.isNotEmpty && reply2[0] == 0x67) {
      _securityUnlocked = true;
      _log('<<< ${_hexList(reply2)}    (security access granted)');
      return true;
    }
    _log('<<< ${_hexList(reply2)}    (key rejected)');
    return false;
  }

  // ── RoutineControl ($31 0x01) ──────────────────────────────────────────────

  /// UDS $31 0x01 startRoutine for routine ID `0x04XX`.
  ///
  /// Wire (matches Python `BMSUDSClient.run_routine`):
  /// ```
  /// TX: 04 31 01 04 XX 00 00 00
  /// RX: 05 71 01 04 XX <status> ...   (status 0x01 = completed)
  /// ```
  ///
  /// Returns a [RoutineResult] with `accepted` (got a `71 01` back at all)
  /// and `completed` (status byte was 0x01). Both are informative — some
  /// firmwares accept a routine and report progress with a different status.
  Future<RoutineResult> runRoutine(int routineId) async {
    final hi = (routineId >> 8) & 0xFF;
    final lo = routineId & 0xFF;
    _log('>>> 31 01 ${_h(hi)} ${_h(lo)}   (startRoutine 0x${_h(hi)}${_h(lo)})');
    List<int> reply;
    try {
      reply = await _send([0x31, 0x01, hi, lo]);
    } on IsoTpNegativeResponse catch (e) {
      _log('!! ${e.message}');
      return RoutineResult(
          accepted: false, completed: false, statusByte: null,
          error: e.message);
    } on IsoTpTimeout catch (e) {
      _log('!! timeout: ${e.message}');
      return RoutineResult(
          accepted: false, completed: false, statusByte: null,
          error: e.message);
    } catch (e) {
      _log('!! error: $e');
      return RoutineResult(
          accepted: false, completed: false, statusByte: null,
          error: '$e');
    }
    _log('<<< ${_hexList(reply)}');
    if (reply.length >= 4 &&
        reply[0] == 0x71 &&
        reply[1] == 0x01 &&
        reply[2] == hi &&
        reply[3] == lo) {
      final status = reply.length > 4 ? reply[4] : null;
      final completed = status == 0x01;
      return RoutineResult(
          accepted: true, completed: completed, statusByte: status);
    }
    return RoutineResult(
        accepted: false, completed: false, statusByte: null,
        error: 'unexpected reply');
  }

  // ── TesterPresent keepalive ────────────────────────────────────────────────

  /// Start firing `3E 80` (TesterPresent, suppress-positive-response bit
  /// set) at [interval]. Tesla BMS drops the extended diagnostic session
  /// after ~5 s of silence, so this is required whenever we intend to
  /// leave a Run tap sitting idle between routines.
  void startKeepAlive({
    Duration interval = const Duration(milliseconds: 4500),
  }) {
    stopKeepAlive();
    _keepAliveTimer = Timer.periodic(interval, (_) async {
      if (_busy) return; // skip a tick if a real request is in flight
      try {
        // Suppress-positive-response bit set → ECU sends no reply.
        await _ch?.sendNoReply([0x3E, 0x80]);
      } catch (_) {}
    });
  }

  void stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<List<int>> _send(List<int> data) async {
    final ch = _ch;
    if (ch == null) {
      throw StateError('BmsUdsClient not open — call open() first');
    }
    // Serialize to make sure keepalive can never race with a routine call.
    _busy = true;
    try {
      return await ch.sendRecv(data);
    } finally {
      _busy = false;
    }
  }

  void _log(String s) => onLog?.call(s);

  static String _h(int b) =>
      b.toRadixString(16).toUpperCase().padLeft(2, '0');
  static String _hexList(List<int> bytes) => bytes.map(_h).join(' ');
}

/// The T-Clear / Black Hat 2020 algorithm: XOR each seed byte with 0x35.
List<int> _defaultSeedToKey(List<int> seed) =>
    [for (final b in seed) (b ^ 0x35) & 0xFF];

/// Return value of [BmsUdsClient.runRoutine].
class RoutineResult {
  /// True if the ECU echoed `71 01 <id_hi> <id_lo> …` — routine
  /// exists and was accepted for execution.
  final bool accepted;

  /// True if the status byte was 0x01 (routine completed successfully).
  /// Some firmwares report other statuses (e.g. 0x02 = pending) — still
  /// counts as accepted but not "completed".
  final bool completed;

  /// Raw status byte from the positive response, or null if the response
  /// was too short to carry one, or if no response came back at all.
  final int? statusByte;

  /// Human message if the request failed outright (NRC / timeout /
  /// unexpected reply). Null on any accepted response.
  final String? error;

  const RoutineResult({
    required this.accepted,
    required this.completed,
    required this.statusByte,
    this.error,
  });

  String get label {
    if (!accepted) return 'REJECTED: ${error ?? 'no positive response'}';
    if (completed) return 'completed (status 0x01)';
    if (statusByte != null) {
      return 'accepted (status 0x${statusByte!.toRadixString(16).toUpperCase().padLeft(2, '0')})';
    }
    return 'accepted (no status byte)';
  }
}
