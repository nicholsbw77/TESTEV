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

/// Open the extended diagnostic session (0x10 0x03) and pass SecurityAccess
/// levels 5/6. Returns true iff the BMS acknowledges SendKey.
///
/// The client's request header must already be set for the pack BMS
/// (typically 0x602 → 0x612). Session preamble is unaware of the routine
/// that will follow, so call [UdsClient.setSession] with `reqCanId: 0x602`
/// before this function, then call `setSession` again if a subsequent
/// routine uses a different header (e.g. 0x601 for isolation clears).
Future<SecurityResult> openSecurityAccessSession(
  UdsClient uds, {
  SeedToKey seedToKey = _fixedKey,
}) async {
  // 1. Extended diagnostic session
  final sess = await uds.sendExpect('02 10 03', '50 03');
  if (!sess) return SecurityResult.sessionFailed;

  // 2. RequestSeed (level 5) — reply is an ISO-TP first frame:
  //      612 10 12 67 05 <seed[0..2]>
  //      612 21 <seed[3..9]>
  //      612 22 <seed[10..15]> 00 00
  final seedReply = await uds
      .sendHex('02 27 05', expect: '67 05', timeout: const Duration(seconds: 3))
      .catchError((_) => '');
  if (seedReply.isEmpty) return SecurityResult.seedFailed;

  final seed = _extractSeed(seedReply);
  if (seed.length != 16) return SecurityResult.seedFailed;
  final key = seedToKey(seed);
  if (key.length != 16) {
    throw ArgumentError('seedToKey must return exactly 16 bytes, got ${key.length}');
  }

  // 3. SendKey (level 6) — needs multi-frame ISO-TP: 12 header+data bytes
  //    (0x27 0x06 + 16 key bytes = 18 bytes total = 0x12).
  //      Send:  10 12 27 06 k0 k1 k2 k3          (First Frame)
  //             21 k4 k5 k6 k7 k8 k9 k10          (Consecutive #1)
  //             22 k11 k12 k13 k14 k15 00 00      (Consecutive #2, padded)
  //      Expect: 612 02 67 06

  final firstFrame = '10 12 27 06 '
      '${_h(key[0])} ${_h(key[1])} ${_h(key[2])} ${_h(key[3])}';
  final cf1 = '21 '
      '${_h(key[4])} ${_h(key[5])} ${_h(key[6])} ${_h(key[7])} '
      '${_h(key[8])} ${_h(key[9])} ${_h(key[10])}';
  final cf2 = '22 '
      '${_h(key[11])} ${_h(key[12])} ${_h(key[13])} ${_h(key[14])} '
      '${_h(key[15])} 00 00';

  // First frame — the BMS should reply with a flow-control 30 XX YY.
  await uds
      .sendHex(firstFrame, expect: '30 ', timeout: const Duration(seconds: 2))
      .catchError((_) => '');
  // Small breath between CFs (matches T-Clear's Thread.Sleep(500))
  await Future.delayed(const Duration(milliseconds: 400));
  await uds
      .sendHex(cf1, timeout: const Duration(seconds: 1))
      .catchError((_) => '');
  await Future.delayed(const Duration(milliseconds: 400));
  final ok = await uds.sendExpect(cf2, '67 06',
      timeout: const Duration(seconds: 3));
  return ok ? SecurityResult.success : SecurityResult.keyRejected;
}

enum SecurityResult {
  success,
  sessionFailed,     // 0x10 0x03 not accepted
  seedFailed,        // 0x27 0x05 returned no/malformed seed
  keyRejected,       // 0x27 0x06 negative response (0x7F 0x27 …)
}

extension SecurityResultLabel on SecurityResult {
  String get label => switch (this) {
        SecurityResult.success        => 'Security-access OK',
        SecurityResult.sessionFailed  => 'Session request rejected (0x10 0x03)',
        SecurityResult.seedFailed     => 'Seed request rejected (0x27 0x05)',
        SecurityResult.keyRejected    => 'Key rejected (0x27 0x06)',
      };
}

// ── helpers ────────────────────────────────────────────────────────────────

String _h(int b) => b.toRadixString(16).toUpperCase().padLeft(2, '0');

/// Parse the multi-line ELM reply to `02 27 05` into a 16-byte seed.
/// Expected shape (spaces on, header on):
///     612 10 12 67 05 XX XX XX
///     612 21 XX XX XX XX XX XX XX
///     612 22 XX XX XX XX XX 00 00
List<int> _extractSeed(String reply) {
  final lines = reply
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim().toUpperCase())
      .where((l) => l.isNotEmpty && l != '>')
      .toList();
  final seed = <int>[];
  for (final line in lines) {
    final toks = line.split(RegExp(r'\s+'));
    // Drop CAN ID (3 hex chars in first token)
    if (toks.isEmpty) continue;
    List<String> payload = toks.length > 1 ? toks.sublist(1) : [];
    // First frame:  10 12 67 05 <s0 s1 s2>
    if (payload.length >= 5 && payload[0] == '10') {
      // skip length + service + subfn = 3 tokens after '10'
      seed.addAll(payload.sublist(4).map(_hexByte).whereType<int>());
    } else if (payload.isNotEmpty && payload[0].startsWith('2')) {
      // Consecutive frame:  21/22 <bytes...>
      seed.addAll(payload.sublist(1).map(_hexByte).whereType<int>());
    }
    if (seed.length >= 16) break;
  }
  // Trim any trailing padding bytes if we over-collected.
  return seed.length > 16 ? seed.sublist(0, 16) : seed;
}

int? _hexByte(String t) {
  if (t.length != 2) return null;
  return int.tryParse(t, radix: 16);
}
