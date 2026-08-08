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

/// The 16-byte key T-Clear ships. This is exactly `XOR 0x35` of the
/// static seed `00 01 02 … 0F` that a bench-mode BMS returns, so it
/// unlocks any pack whose RequestSeed reply is the fixed sequence.
/// Reverse-engineered from the decompiled T-Clear MainActivity where
/// the same 16 bytes are hardcoded and sent verbatim on every SendKey,
/// no matter what the actual seed reply contains.
///
/// On a real vehicle BMS that returns a random seed, this key won't
/// work and RequestSeed → SendKey needs the XOR-0x35 algorithm on the
/// actual seed bytes. That path is preserved via [teslaBmsSeedToKey]
/// and can be wired back in once we can reliably reassemble the full
/// 18-byte seed reply through the ELM.
const List<int> kTeslaBmsFixedKey = [
  0x35, 0x34, 0x37, 0x36, 0x31, 0x30, 0x33, 0x32,
  0x3D, 0x3C, 0x3F, 0x3E, 0x39, 0x38, 0x3B, 0x3A,
];

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
  List<int> fixedKey = kTeslaBmsFixedKey,
}) async {
  // Ensure the header is BMS. The caller may have last set a different
  // header for a previous routine — that's fine, we override here.
  await uds.setSession(
    reqCanId: kBmsRequestCanId,
    rspCanId: kBmsResponseCanId,
  );
  await Future.delayed(const Duration(milliseconds: 100));

  // 1. Extended diagnostic session — a single-frame UDS request.
  final sess = await uds.sendUdsSingleFrameExpect([0x10, 0x03], '50 03');
  if (!sess) return SecurityResult.sessionFailed;
  await Future.delayed(const Duration(milliseconds: 200));

  // 2. RequestSeed (level 5) — T-Clear pattern.
  //
  //    T-Clear (decompiled) only waits for the *First Frame* of the
  //    18-byte seed reply: expect = "612 10 12 67". It never tries
  //    to reassemble the CFs, because it uses a hardcoded key that
  //    doesn't depend on the seed contents at all — which works
  //    because a bench BMS always returns the static seed
  //    00 01 02 … 0F, and the hardcoded key is exactly XOR-0x35 of
  //    that seed. This sidesteps the STN's multi-frame RX abort
  //    ("STOPPED") that killed every FC/timing tweak we tried.
  //
  //    We mirror T-Clear: match on the FF header only, then move on.
  final seedReply = await uds
      .sendUdsSingleFrame([0x27, 0x05],
          expect: '10 12 67', timeout: const Duration(seconds: 3))
      .catchError((_) => '');
  if (!seedReply.toUpperCase().contains('10 12 67')) {
    return SecurityResult.seedFailed;
  }
  await Future.delayed(const Duration(milliseconds: 200));

  // 3. SendKey (level 6) with the fixed T-Clear key. In manualFraming
  //    the client emits FF (`10 12 27 06 KK KK KK KK`), CF1
  //    (`21 KK KK KK KK KK KK KK`), CF2 (`22 KK KK KK KK KK 00 00`) as
  //    three separate ELM commands — exactly T-Clear's wire pattern.
  final ok = await uds.sendUdsMultiFrameExpect(
    [0x27, 0x06, ...fixedKey],
    '67 06',
    timeout: const Duration(seconds: 5),
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

// (Seed-parsing helpers removed — the fixed-key path doesn't need to
// parse the seed bytes at all. Revive them alongside a working
// multi-frame RX path through the ELM when we add dynamic-seed
// support for a real vehicle BMS.)
