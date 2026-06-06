import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'pack_state.dart';
import '../decoder/constants.dart';

class SessionLogger {
  static final List<String> header = [
    'timestamp', 'source', 'pack_v', 'pack_i', 'soc_pct',
    'isolation_kohm', 'kwh_charged', 'kwh_discharged',
    'contactor_state', 'neg_term_temp_c',
    'cell_v_min', 'cell_v_max', 'cell_v_delta',
    'balance_active',
    ...List.generate(numCells, (i) => 'cell_${(i + 1).toString().padLeft(2, '0')}'),
    ...List.generate(numModules, (m) => 'mod_${(m + 1).toString().padLeft(2, '0')}_v'),
    ...List.generate(numModules, (m) => 'mod_${(m + 1).toString().padLeft(2, '0')}_t1'),
    ...List.generate(numModules, (m) => 'mod_${(m + 1).toString().padLeft(2, '0')}_t2'),
    'alerts',
  ];

  File? _file;
  IOSink? _sink;
  int _rowsWritten = 0;
  final DateTime _startTime = DateTime.now();
  final String mode;

  SessionLogger({this.mode = 'can'});

  int get rowsWritten => _rowsWritten;
  String? get filePath => _file?.path;

  Future<void> start() async {
    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${dir.path}/logs');
    if (!logDir.existsSync()) logDir.createSync(recursive: true);

    final ts = _startTime.toIso8601String().replaceAll(':', '').substring(0, 15);
    _file = File('${logDir.path}/${ts}_${mode}_session.csv');
    _sink = _file!.openWrite();
    _sink!.writeln(const ListToCsvConverter().convert([header]));
    await _sink!.flush();
  }

  void logState(PackState state) {
    if (_sink == null) return;

    final ts = DateTime.now().toIso8601String();
    final row = <String>[
      ts,
      state.modeLabel,
      _fmt(state.bestPackVoltage, 2),
      _fmt(state.packCurrent, 2),
      _fmt(state.soc, 1),
      _fmt(state.isolationKohm, 0),
      _fmt(state.kwhCharged, 2),
      _fmt(state.kwhDischarged, 2),
      state.contactorState,
      _fmt(state.negTerminalTempC, 1),
      _fmt(state.cellMin, 4),
      _fmt(state.cellMax, 4),
      _fmt(state.cellDeltaMv, 2),
      '0',
      ...state.cells.map((v) => _fmt(v, 4)),
      ...List.generate(numModules, (m) => _fmt(state.moduleSum(m), 3)),
      ...List.generate(numModules, (m) => _fmt(state.temps[m].$1, 1)),
      ...List.generate(numModules, (m) => _fmt(state.temps[m].$2, 1)),
      '',
    ];

    _sink!.writeln(const ListToCsvConverter().convert([row]));
    _rowsWritten++;
  }

  Future<String> stop() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;

    final duration = DateTime.now().difference(_startTime);
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;

    // Write session info
    if (_file != null) {
      final infoPath = _file!.path.replaceAll('_session.csv', '_session_info.txt');
      final info = File(infoPath);
      await info.writeAsString(
        'TESTEV Session Summary\n'
        '${'=' * 50}\n\n'
        'Mode:           $mode\n'
        'Start:          $_startTime\n'
        'Duration:       ${m}m ${s}s\n'
        'Rows logged:    $_rowsWritten\n',
      );
    }

    return _file?.path ?? '';
  }

  static String _fmt(double v, int decimals) {
    if (v.isNaN || v.isInfinite) return '';
    return v.toStringAsFixed(decimals);
  }
}
