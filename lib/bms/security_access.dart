import 'uds_client.dart';

/// A caller-supplied seed→key function. Given the 16-byte seed the BMS
/// returns for RequestSeed level 5, return the 16 key bytes to send with
/// SendKey level 6.
typedef SeedToKey = List<int> Function(List<int> seed);

/// The T-Clear app's fixed 16-byte key. It replays the same key regardless
/// of the seed the BMS returns — this works on the Model S/X packs T-Clear
/// supports because the firmware happens to accept it. Swap in your own
/// [SeedToKey] if you have the real algorithm.
const List<int> kTClearFixedKey = [
  0x35, 0x34, 0x37, 0x36, 0x31, 0x30, 0x33, 0x32,
  0x3D, 0x3C, 0x3F, 0x3E, 0x39, 0x38, 0x3B, 0x3A,
];

List<int> _fixedKey(List<int> _) => kTClearFixedKey;

/// The Tesla Model S/X pack BMS UDS request CAN ID. Session + security
/// **always** target this address, even when the routine that follows lives
/// on a different header (e.g. 0x601 for isolation clears). The T-Clear
/// app does the same.
const int kBmsRequestCanId = 0x602;

/// Open the extended diagnostic session (0x10 0x03) and pass SecurityAccess
/// levels 5/6 against the BMS at [kBmsRequestCanId].
///
/// Payloads are sent in **CAN auto-format (CAF-on)** style — just the raw
/// UDS service bytes, no ISO-TP length prefix. The ELM327 assembles the
/// ISO-TP frame(s) and re-flattens multi-frame responses for us. That
/// works uniformly on the OBDLink STN and on older ELM327 firmwares like
/// the one WiCAN's emulator ships (v1.3a).
Future<SecurityResult> openSecurityAccessSession(
  UdsClient uds, {
  SeedToKey seedToKey = _fixedKey,
}) async {
  // Ensure the header is BMS. The caller may have last set a different
  // header for a previous routine — that's fine, we override here.
  await uds.setSession(reqCanId: kBmsRequestCanId);

  // 1. Extended diagnostic session
  final sess = await uds.sendUdsExpect([0x10, 0x03], '50 03');
  if (!sess) return SecurityResult.sessionFailed;

  // 2. RequestSeed (level 5). Reply is 18 UDS bytes: 67 05 <16-byte seed>.
  //    With CAF-on the ELM aggregates the multi-frame response into one
  //    logical line for us.
  final seedReply = await uds
      .sendUds([0x27, 0x05], expect: '67 05', timeout: const Duration(seconds: 3))
      .catchError((_) => '');
  if (seedReply.isEmpty) return SecurityResult.seedFailed;

  final seed = _extractSeed(seedReply);
  if (seed.length != 16) return SecurityResult.seedFailed;
  final key = seedToKey(seed);
  if (key.length != 16) {
    throw ArgumentError('seedToKey must return exactly 16 bytes, got ${key.length}');
  }

  // 3. SendKey (level 6). 18 UDS bytes total (0x27 0x06 + 16 key bytes).
  //    With CAF-on the ELM handles ISO-TP fragmentation, the ECU's flow-
  //    control response, and the wait for the ECU's positive/negative
  //    response — we just give it the payload and match "67 06" back.
  final ok = await uds.sendUdsExpect(
    [0x27, 0x06, ...key],
    '67 06',
    timeout: const Duration(seconds: 4),
  );
  return ok ? SecurityResult.success : SecurityResult.keyRejected;
}

enum SecurityResult {
  success,
  sessionFailed,     // 0x10 0x03 not accepted (or NO DATA — car off/asleep)
  seedFailed,        // 0x27 0x05 returned no/malformed seed
  keyRejected,       // 0x27 0x06 negative response (0x7F 0x27 …)
}

extension SecurityResultLabel on SecurityResult {
  String get label => switch (this) {
        SecurityResult.success        => 'Security-access OK',
        SecurityResult.sessionFailed  => 'Session request rejected (0x10 0x03) — car on? contactors closed? adapter powered?',
        SecurityResult.seedFailed     => 'Seed request rejected (0x27 0x05)',
        SecurityResult.keyRejected    => 'Key rejected (0x27 0x06)',
      };
}

// ── helpers ────────────────────────────────────────────────────────────────

/// Parse the ELM reply to `27 05` into a 16-byte seed.
/// With CAF-on the ELM typically returns one line like:
///     612 67 05 XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX
/// but some firmwares still emit the raw ISO-TP frames:
///     612 10 12 67 05 XX XX XX
///     612 21 XX XX XX XX XX XX XX
///     612 22 XX XX XX XX XX 00 00
/// The parser handles either shape.
List<int> _extractSeed(String reply) {
  final seed = <int>[];
  for (final line in reply.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim().toUpperCase();
    if (t.isEmpty || t == '>') continue;
    final toks = t.split(RegExp(r'\s+'));
    if (toks.isEmpty) continue;

    // Drop the CAN ID if it looks like a 3-char hex header (ATH1 on).
    List<String> payload = toks;
    if (toks[0].length == 3 && int.tryParse(toks[0], radix: 16) != null) {
      payload = toks.sublist(1);
    }
    if (payload.isEmpty) continue;

    // Case A: raw ISO-TP framing surfaces.
    if (payload[0] == '10' && payload.length >= 5) {
      // First frame: 10 <len> 67 05 <seed[0..2]>
      seed.addAll(payload.sublist(4).map(_hexByte).whereType<int>());
      continue;
    }
    if (RegExp(r'^2[0-9A-F]$').hasMatch(payload[0]) && payload.length >= 2) {
      // Consecutive frame: 2N <seed bytes>
      seed.addAll(payload.sublist(1).map(_hexByte).whereType<int>());
      continue;
    }
    // Case B: ELM aggregated — payload starts with 67 05 <seed...>
    final serviceIdx = payload.indexOf('67');
    if (serviceIdx >= 0 && payload.length > serviceIdx + 2 &&
        payload[serviceIdx + 1] == '05') {
      seed.addAll(payload.sublist(serviceIdx + 2).map(_hexByte).whereType<int>());
      continue;
    }
  }
  // Trim any trailing padding bytes if we over-collected.
  return seed.length > 16 ? seed.sublist(0, 16) : seed;
}

int? _hexByte(String t) {
  if (t.length != 2) return null;
  return int.tryParse(t, radix: 16);
}
