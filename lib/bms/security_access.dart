import 'uds_client.dart';

/// A caller-supplied seed→key function. Given the 16-byte seed the BMS
/// returns for RequestSeed level 5, return the 16 key bytes to send with
/// SendKey level 6.
typedef SeedToKey = List<int> Function(List<int> seed);

/// The Tesla Model S BMS security algorithm: **XOR each seed byte with 0x35**.
/// Confirmed against Black Hat USA 2020 reverse-engineering + community
/// verification, and cross-checked against the T-Clear "fixed key" — the
/// bench pack T-Clear was tested against always returns the static seed
/// `00 01 02 … 0F`, which XOR'd with 0x35 gives exactly T-Clear's
/// hard-coded key `35 34 37 36 31 30 33 32 3D 3C 3F 3E 39 38 3B 3A`.
/// On packs that return a dynamic seed, the XOR algo is the one that
/// works.
List<int> teslaBmsSeedToKey(List<int> seed) =>
    [for (final b in seed) (b ^ 0x35) & 0xFF];

/// The Tesla Model S/X pack BMS UDS request CAN ID. Session + security
/// **always** target this address, even when the routine that follows lives
/// on a different header (e.g. 0x601 for isolation clears). The T-Clear
/// app does the same.
const int kBmsRequestCanId  = 0x602;
const int kBmsResponseCanId = 0x612;

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
  SeedToKey seedToKey = teslaBmsSeedToKey,
}) async {
  // Ensure the header is BMS. The caller may have last set a different
  // header for a previous routine — that's fine, we override here.
  await uds.setSession(
    reqCanId: kBmsRequestCanId,
    rspCanId: kBmsResponseCanId,
  );

  // For the whole security-access exchange, force the ELM into CAN
  // auto-formatting mode (ATCAF1). In CAF-off mode the STN aborts
  // the 18-byte seed reassembly with STOPPED — its manual-framing
  // path evidently can't complete FF + 2×CF for this non-OBD service
  // (verified across three FC modes and with the timing pauses the
  // reference Python uses). CAF-on hands the whole ISO-TP job to
  // the ELM, which is a completely different code path in the STN
  // and is the one the reference Python's udsoncan+can-isotp stack
  // effectively drives. After security completes we restore CAF-off
  // so the single-frame routine sends keep their T-Clear-style wire
  // format (`0N XX XX XX 00 00 00 00`).
  final restoreManual = uds.manualFraming;
  await uds.setCanAutoFormat(true);

  try {
    await Future.delayed(const Duration(milliseconds: 100));

    // 1. Extended diagnostic session — a single-frame UDS request.
    final sess = await uds.sendUdsSingleFrameExpect([0x10, 0x03], '50 03');
    if (!sess) return SecurityResult.sessionFailed;

    // 2. RequestSeed (level 5). Reply is 18 UDS bytes: 67 05 + 16 seed
    //    bytes. In CAF-on the ELM reassembles the whole thing and hands
    //    us a single flat line: `612 67 05 XX … XX`.
    //
    //    Give the BMS ~200 ms to finish transitioning into the extended
    //    session before we hit it with 27 05 (matches Python's
    //    `time.sleep(0.1)` between session and security_access).
    await Future.delayed(const Duration(milliseconds: 200));
    final seedReply = await uds
        .sendUdsSingleFrame([0x27, 0x05],
            expect: '67 05', timeout: const Duration(seconds: 5))
        .catchError((_) => '');
    if (seedReply.isEmpty) return SecurityResult.seedFailed;

    final seed = _extractSeed(seedReply);
    if (seed.length != 16) return SecurityResult.seedFailed;
    final key = seedToKey(seed);
    if (key.length != 16) {
      throw ArgumentError(
          'seedToKey must return exactly 16 bytes, got ${key.length}');
    }

    // 3. SendKey (level 6). 18 UDS bytes total (0x27 0x06 + 16 key
    //    bytes). CAF-on lets the ELM auto-fragment the request into
    //    FF + CFs and reassemble the `67 06` positive reply.
    await Future.delayed(const Duration(milliseconds: 200));
    final ok = await uds.sendUdsMultiFrameExpect(
      [0x27, 0x06, ...key],
      '67 06',
      timeout: const Duration(seconds: 5),
    );
    return ok ? SecurityResult.success : SecurityResult.keyRejected;
  } finally {
    // Restore manual framing so single-frame routine sends keep the
    // T-Clear wire form. If the adapter refused ATCAF0 during init
    // (WiCAN v1.3a), restoreManual is already false and the call
    // just no-ops on the mode flag.
    if (restoreManual) {
      await uds.setCanAutoFormat(false);
    }
  }
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
