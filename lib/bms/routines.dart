/// Tesla BMS routineControl (0x31 0x01) commands for the 2013 Model S BMS.
///
/// Every routine is a single ISO-TP frame:
///   request:  31 01 04 XX               (routineIdentifier 0x04XX)
///   response: `71 01 04 XX <status>`   (positive; status 0x01 = completed)
///
/// All routines require an extended diagnostic session (0x10 0x03) and
/// SecurityAccess level 5/6 (XOR-0x35) to have been established first.
///
/// Two source lists, unified here:
///
/// * **T-Clear catalog** (from the shipping T-Clear Android app,
///   `tclear_model_s_x.json`) — the primary source. Ten routine IDs
///   attested by a working commercial app.
///
/// * **Bench GUI `can_reader/uds.py`** — one extra ID (0x0407, Reset WOT)
///   not present in T-Clear, kept for completeness.
///
/// Where the two sources disagree on the target CAN ID for a routine
/// (T-Clear ships some as 0x601, the Python targets everything on 0x602),
/// the Python wins here because the Python is the one that has actually
/// been observed to unlock security and issue requests successfully.
/// Single header 0x602/0x612 for every routine.
library;

class Routine {
  final int routineId;             // 16-bit routineIdentifier, e.g. 0x0405
  final String label;
  final List<String> faults;
  final RoutineSource source;

  const Routine({
    required this.routineId,
    required this.label,
    this.faults = const [],
    this.source = RoutineSource.tclear,
  });

  /// Tesla BMS request CAN ID (fixed for the whole catalog).
  int get reqCanId => 0x602;

  /// Tesla BMS response CAN ID (fixed for the whole catalog).
  int get respCanId => 0x612;

  String get hexId =>
      '0x${routineId.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

enum RoutineSource { tclear, benchGui }

/// Per-fault routine table. Order matters only inside composites.
const List<Routine> kRoutines = [
  Routine(routineId: 0x0401,
      label: 'Clear W026',
      faults: ['BMS_w026_SW_Ctrs_Disabled']),
  Routine(routineId: 0x0402,
      label: 'Clear W163 / W023 / Open Positive Contactor',
      faults: [
        'BMS_w163_SW_Contactor_WOT_Count',
        'BMS_w023_SW_Contactors_Open_HWOC',
      ]),
  Routine(routineId: 0x0404,
      label: 'Clear F152 (pos contactor welded)',
      faults: ['BMS_f152_SW_pos_contactor_welded']),
  Routine(routineId: 0x0405,
      label: 'Clear F153 / U008 step 1',
      faults: [
        'BMS_f153_SW_neg_contactor_welded',
        'BMS_u008_limpMode',
      ]),
  Routine(routineId: 0x0406,
      label: 'Clear Contactor Stress (BMS_u029 source)',
      faults: ['BMS_w161_SW_Contactor_Stress']),
  Routine(routineId: 0x0407,
      label: 'Reset WOT counter  (bench-GUI list only)',
      source: RoutineSource.benchGui),
  Routine(routineId: 0x040A,
      label: 'Clear F027 / F172 (isolation counters)',
      faults: [
        'BMS_w027_SW_isolation',
        'BMS_w172_SW_isolation',
      ]),
  Routine(routineId: 0x040B,
      label: 'Clear F107 / F177 (part 1)',
      faults: [
        'BMS_f107_SW_Cell_Voltage_Sensor',
        'BMS_f177_OpenVshDetected',
      ]),
  Routine(routineId: 0x040C,
      label: 'Clear U029 dSoC_Limiting  — only after root cause fixed',
      faults: ['BMS_u029_dSoc_Limiting']),
  Routine(routineId: 0x040D,
      label: 'Clear F107 / F177 (part 2)',
      faults: [
        'BMS_f107_SW_Cell_Voltage_Sensor',
        'BMS_f177_OpenVshDetected',
      ]),
  Routine(routineId: 0x0412,
      label: 'Reset CAC (amp-hour / range recalibrate)'),
];

/// Multi-step recipes taken verbatim from T-Clear.
const Map<String, List<int>> kComposites = {
  'clear_u008_limp_mode': [0x0405, 0x0406, 0x0404, 0x040A],
  'clear_f107_f177':      [0x040B, 0x040D],
};

Routine? routineById(int id) {
  for (final r in kRoutines) {
    if (r.routineId == id) return r;
  }
  return null;
}
