/// Tesla BMS routineControl (0x31 0x01) commands distilled from the T-Clear
/// Android app.
///
/// Every routine is a single ISO-TP frame:
///   request:  04 31 01 04 XX 00 00 00     (routineIdentifier = 0x04XX)
///   response: 05 71 01 04 XX               (positive response 0x71)
///
/// All routines require an extended diagnostic session (0x10 0x03) and
/// SecurityAccess levels 5/6 to have been established first — see
/// `security_access.dart`.
library;

class Routine {
  final int routineId;   // 16-bit routineIdentifier, e.g. 0x0405
  final int reqCanId;    // request CAN arbitration ID
  final int respCanId;   // response CAN arbitration ID (req + 0x010)
  final String label;
  final List<String> faults;

  const Routine({
    required this.routineId,
    required this.reqCanId,
    required this.respCanId,
    required this.label,
    this.faults = const [],
  });

  /// ISO-TP single-frame bytes as sent on the bus (8 bytes, zero-padded).
  List<int> get requestPayload {
    final hi = (routineId >> 8) & 0xFF;
    final lo = routineId & 0xFF;
    return [0x04, 0x31, 0x01, hi, lo, 0x00, 0x00, 0x00];
  }

  /// Positive-response ISO-TP single-frame bytes (first 5 significant bytes).
  List<int> get expectedResponse {
    final hi = (routineId >> 8) & 0xFF;
    final lo = routineId & 0xFF;
    return [0x05, 0x71, 0x01, hi, lo];
  }

  String get hexId => '0x${routineId.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

/// Per-fault routine table (Model S/X). Order matters only inside composites.
const List<Routine> kRoutines = [
  Routine(routineId: 0x0401, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear W026',
      faults: ['BMS_w026_SW_Ctrs_Disabled']),
  Routine(routineId: 0x0402, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear W163 / W023',
      faults: ['BMS_w163_SW_Contactor_WOT_Count', 'BMS_w023_SW_Contactors_Open_HWOC']),
  Routine(routineId: 0x0404, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear F152',
      faults: ['BMS_f152_SW_pos_contactor_welded']),
  Routine(routineId: 0x0405, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear F153 / U008 (step 1)',
      faults: ['BMS_f153_SW_neg_contactor_welded', 'BMS_u008_limpMode']),
  Routine(routineId: 0x0406, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear Contactor Stress (also part of U008)',
      faults: ['BMS_w161_SW_Contactor_Stress']),
  Routine(routineId: 0x040A, reqCanId: 0x601, respCanId: 0x611,
      label: 'Clear F027 / F172 (isolation counters)',
      faults: ['BMS_w027_SW_isolation', 'BMS_w172_SW_isolation']),
  Routine(routineId: 0x040B, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear F107 / F177 (part 1)',
      faults: ['BMS_f107_SW_Cell_Voltage_Sensor', 'BMS_f177_OpenVshDetected']),
  Routine(routineId: 0x040C, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear U029 dSoC_Limiting  — only run after fixing the root cause',
      faults: ['BMS_u029_dSoc_Limiting']),
  Routine(routineId: 0x040D, reqCanId: 0x602, respCanId: 0x612,
      label: 'Clear F107 / F177 (part 2)',
      faults: ['BMS_f107_SW_Cell_Voltage_Sensor', 'BMS_f177_OpenVshDetected']),
  Routine(routineId: 0x0412, reqCanId: 0x601, respCanId: 0x611,
      label: 'Reset CAC (amp-hour / range recalibrate)'),
];

/// Multi-step recipes taken verbatim from the T-Clear app.
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
