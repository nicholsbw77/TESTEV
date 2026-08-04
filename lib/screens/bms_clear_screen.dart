import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../bms/routines.dart';
import '../bms/security_access.dart';
import '../bms/uds_client.dart';
import '../can/elm327_adapter.dart';
import '../can/elm327_ea_adapter.dart';
import '../can/elm327_base.dart';
import '../can/elm327_tcp_adapter.dart';

/// Which physical adapter path the BMS-Clear screen should use.
enum _AdapterChoice { obdlinkBluetooth, wicanWiFi }

/// Supported vehicles. Right now only Model S/X routines are known; Model 3
/// is listed but disabled so the user can't accidentally pick it.
enum _VehicleModel { unknown, sX, model3 }

extension on _VehicleModel {
  String get label => switch (this) {
        _VehicleModel.unknown => '— select model —',
        _VehicleModel.sX      => 'Model S / X',
        _VehicleModel.model3  => 'Model 3 (not supported yet)',
      };
  bool get supported => this == _VehicleModel.sX;
}

/// BMS DTC-clear screen. Owns its own ELM adapter instance so it doesn't
/// fight with the dashboard's monitor-mode session.
class BmsClearScreen extends StatefulWidget {
  const BmsClearScreen({super.key});

  @override
  State<BmsClearScreen> createState() => _BmsClearScreenState();
}

class _BmsClearScreenState extends State<BmsClearScreen> {
  Elm327Base? _adapter;
  UdsClient? _uds;
  final List<String> _log = [];
  final ScrollController _logCtrl = ScrollController();

  String _status = 'Not connected';
  bool _busy = false;
  bool _sessionOpen = false;      // extended session + SecurityAccess passed
  int? _currentReqCanId;          // last CAN ID we set via ATSH

  _AdapterChoice _adapterChoice = Platform.isIOS
      ? _AdapterChoice.obdlinkBluetooth   // iOS defaults to MFi OBDLink
      : _AdapterChoice.obdlinkBluetooth;
  _VehicleModel _model = _VehicleModel.unknown;

  // Cached from SharedPreferences (set by ConnectScreen when the user
  // connects the dashboard over WiFi to a WiCAN).
  String _wicanHost = '192.168.50.158';
  int _wicanPort = 3333;

  static const _kLastHostKey = 'wican_last_host';
  static const _kLastPortKey = 'wican_last_port';

  @override
  void initState() {
    super.initState();
    _loadWicanEndpoint();
  }

  Future<void> _loadWicanEndpoint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _wicanHost = prefs.getString(_kLastHostKey) ?? _wicanHost;
      _wicanPort = int.tryParse(prefs.getString(_kLastPortKey) ?? '') ?? _wicanPort;
    });
  }

  @override
  void dispose() {
    _teardown();
    _logCtrl.dispose();
    super.dispose();
  }

  // ── connection lifecycle ──────────────────────────────────────────────

  Future<void> _connect() async {
    if (_adapter != null) return;
    final monitorOn = context.read<AppModel>().isConnected;
    if (monitorOn) {
      _snack('Disconnect the dashboard monitor first '
          '(it holds the adapter serial link).');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Connecting…';
    });
    _appendLog('--- Connecting ---');
    try {
      final adapter = _makePlatformAdapter();
      final uds = UdsClient(adapter, onLog: _appendLog);
      await uds.initialize();
      _adapter = adapter;
      _uds = uds;
      setState(() {
        _status = 'ELM initialized — ready';
      });
    } catch (e) {
      _appendLog('!! connect failed: $e');
      setState(() => _status = 'Connect failed: $e');
      await _teardown();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Elm327Base _makePlatformAdapter() {
    void status(String m) => _appendLog('elm: $m');
    switch (_adapterChoice) {
      case _AdapterChoice.wicanWiFi:
        return Elm327TcpAdapter(
          host: _wicanHost, port: _wicanPort, onStatus: status);
      case _AdapterChoice.obdlinkBluetooth:
        if (Platform.isIOS) return Elm327EaAdapter(onStatus: status);
        return Elm327Adapter(deviceName: 'OBDLink', onStatus: status);
    }
  }

  /// Open the extended session + SecurityAccess against the BMS (always at
  /// 0x602, matching T-Clear). Whichever CAN ID the caller intends to use
  /// for the *routine* itself is set separately, right before the routine
  /// fires — see [_runRoutine].
  Future<void> _openSession() async {
    final uds = _uds;
    if (uds == null) return;
    _appendLog('--- Opening extended session + SecurityAccess (BMS 0x602) ---');
    final res = await openSecurityAccessSession(uds);
    _currentReqCanId = kBmsRequestCanId;
    _appendLog('security-access result: ${res.label}');
    setState(() {
      _sessionOpen = res == SecurityResult.success;
      _status = res.label;
    });
  }

  Future<void> _teardown() async {
    try {
      await _uds?.close();
    } catch (_) {}
    _uds = null;
    _adapter = null;
    _sessionOpen = false;
    _currentReqCanId = null;
    if (mounted) setState(() => _status = 'Disconnected');
  }

  // ── command execution ─────────────────────────────────────────────────

  Future<void> _runRoutine(Routine r) async {
    final uds = _uds;
    if (uds == null) {
      _snack('Connect first.');
      return;
    }
    if (!_model.supported) {
      _snack('Pick a supported model first.');
      return;
    }
    if (_busy) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Run ${r.label}?'),
        content: Text(
          'This will send routineControl start on request ID '
          '0x${r.reqCanId.toRadixString(16).toUpperCase()} '
          '(routine ${r.hexId}).\n\n'
          'Only run this after the underlying fault has been repaired.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Run')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      if (!_sessionOpen) {
        await _openSession();
      }
      if (!_sessionOpen) {
        _snack('Security-access failed; routine not sent.');
        return;
      }
      // Point ATSH at the routine's own request ID before sending. The
      // security session on 0x602 stays valid — Tesla unlocks per-ECU and
      // the unlock persists across header changes.
      if (_currentReqCanId != r.reqCanId) {
        await uds.setSession(reqCanId: r.reqCanId);
        _currentReqCanId = r.reqCanId;
      }
      _appendLog('--- ${r.label} (${r.hexId}) ---');
      final ok = await uds.sendUdsExpect(
        r.requestBytes,
        r.expectedResponseHex,
        timeout: const Duration(seconds: 3),
      );
      setState(() {
        _status = ok
            ? '${r.label}: positive response'
            : '${r.label}: NO positive response';
      });
    } catch (e) {
      _appendLog('!! error: $e');
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runComposite(String name, List<int> ids) async {
    final routines = ids.map(routineById).whereType<Routine>().toList();
    if (routines.isEmpty) return;
    if (_uds == null) {
      _snack('Connect first.');
      return;
    }
    if (!_model.supported) {
      _snack('Pick a supported model first.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Run composite: $name?'),
        content: Text(
          'This will run ${routines.length} routines in order:\n\n'
          '${routines.map((r) => '  • ${r.hexId}  ${r.label}').join('\n')}\n\n'
          'Only run after repairing the underlying fault.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Run all')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    _appendLog('=== Composite: $name ===');
    try {
      if (!_sessionOpen) await _openSession();
      if (!_sessionOpen) {
        _appendLog('!! security-access failed; aborting composite');
        return;
      }
      for (final r in routines) {
        if (_currentReqCanId != r.reqCanId) {
          await _uds!.setSession(reqCanId: r.reqCanId);
          _currentReqCanId = r.reqCanId;
        }
        _appendLog('--- ${r.label} (${r.hexId}) ---');
        final ok = await _uds!.sendUdsExpect(
          r.requestBytes,
          r.expectedResponseHex,
          timeout: const Duration(seconds: 3),
        );
        _appendLog(ok ? '  -> positive response' : '  -> NO positive response');
        await Future.delayed(const Duration(milliseconds: 400));
      }
      _appendLog('=== composite complete ===');
    } catch (e) {
      _appendLog('!! composite aborted: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  void _appendLog(String line) {
    setState(() {
      _log.add(line);
      if (_log.length > 500) _log.removeRange(0, _log.length - 500);
    });
    // Auto-scroll to bottom after frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logCtrl.hasClients) {
        _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
      }
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final connected = _uds != null;
    final canRun = connected && !_busy && _model.supported;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BMS Clear',
            style: TextStyle(
                color: Color(0xFF00E676),
                fontWeight: FontWeight.w900,
                letterSpacing: 2)),
        actions: [
          IconButton(
            tooltip: connected ? 'Disconnect' : 'Connect',
            icon: Icon(connected ? Icons.link_off : Icons.link),
            onPressed: _busy ? null : (connected ? _teardown : _connect),
          ),
        ],
      ),
      body: Column(
        children: [
          _warningBanner(),
          _adapterAndModelRow(connected),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? (_sessionOpen
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFFEB3B))
                        : const Color(0xFFFF1744),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status,
                      style: const TextStyle(
                          color: Color(0xFFCFD8DC), fontSize: 12)),
                ),
                if (_busy)
                  const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E3A5F)),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _routineList(canRun)),
                const VerticalDivider(width: 1, color: Color(0xFF1E3A5F)),
                Expanded(flex: 2, child: _logView()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _adapterAndModelRow(bool connected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          // Adapter picker — disabled while connected (must disconnect first)
          Expanded(
            flex: 3,
            child: _labeledDropdown<_AdapterChoice>(
              label: 'ADAPTER',
              value: _adapterChoice,
              enabled: !connected && !_busy,
              onChanged: (v) => setState(() => _adapterChoice = v!),
              items: [
                _dropdownItem(_AdapterChoice.obdlinkBluetooth,
                    Platform.isIOS
                        ? 'OBDLink MX+ (MFi)'
                        : 'OBDLink MX+ (BT)'),
                _dropdownItem(_AdapterChoice.wicanWiFi,
                    'WiCAN ELM $_wicanHost:$_wicanPort'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Model picker — must be a supported model for Run to enable
          Expanded(
            flex: 2,
            child: _labeledDropdown<_VehicleModel>(
              label: 'MODEL',
              value: _model,
              enabled: !_busy,
              onChanged: (v) {
                if (v == null || v == _VehicleModel.model3) return;
                setState(() => _model = v);
              },
              items: [
                _dropdownItem(_VehicleModel.unknown, _VehicleModel.unknown.label),
                _dropdownItem(_VehicleModel.sX, _VehicleModel.sX.label),
                _dropdownItem(_VehicleModel.model3, _VehicleModel.model3.label,
                    enabled: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _labeledDropdown<T>({
    required String label,
    required T value,
    required bool enabled,
    required ValueChanged<T?> onChanged,
    required List<DropdownMenuItem<T>> items,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Color(0xFF90CAF9),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1)),
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF16213E),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF1E3A5F)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              isExpanded: true,
              value: value,
              dropdownColor: const Color(0xFF16213E),
              iconEnabledColor: const Color(0xFF90CAF9),
              style: const TextStyle(
                  color: Colors.white, fontSize: 12, fontFamily: 'RobotoMono'),
              onChanged: enabled ? onChanged : null,
              items: items,
            ),
          ),
        ),
      ],
    );
  }

  DropdownMenuItem<T> _dropdownItem<T>(T value, String text,
      {bool enabled = true}) {
    return DropdownMenuItem<T>(
      value: value,
      enabled: enabled,
      child: Text(text,
          style: TextStyle(
              color: enabled ? Colors.white : const Color(0xFF546E7A),
              fontSize: 12)),
    );
  }

  Widget _warningBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0x33FF1744),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: const Text(
        'These commands write to the BMS. Only run each after you have '
        'REPAIRED the underlying fault. Wrong use can cause thermal-runaway '
        'or contactor damage.',
        style: TextStyle(color: Color(0xFFFFCDD2), fontSize: 11),
      ),
    );
  }

  Widget _routineList(bool connected) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final r in kRoutines) _routineTile(r, connected),
        const Divider(color: Color(0xFF1E3A5F)),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text('Composite recipes',
              style: TextStyle(
                  color: Color(0xFF90CAF9),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
        ),
        for (final entry in kComposites.entries)
          _compositeTile(entry.key, entry.value, connected),
      ],
    );
  }

  Widget _routineTile(Routine r, bool connected) {
    return Card(
      child: ListTile(
        dense: true,
        title: Text(r.label,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE0E0E0))),
        subtitle: Text(
          '${r.hexId}  •  req 0x${r.reqCanId.toRadixString(16).toUpperCase()}'
          '${r.faults.isEmpty ? '' : '\n${r.faults.join(", ")}'}',
          style: const TextStyle(
              fontSize: 10, color: Color(0xFF78909C), fontFamily: 'RobotoMono'),
        ),
        trailing: FilledButton.tonal(
          onPressed: (connected && !_busy) ? () => _runRoutine(r) : null,
          child: const Text('Run'),
        ),
      ),
    );
  }

  Widget _compositeTile(String name, List<int> ids, bool connected) {
    return Card(
      child: ListTile(
        dense: true,
        title: Text(name,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE0E0E0))),
        subtitle: Text(
          ids
              .map((id) => '0x${id.toRadixString(16).toUpperCase().padLeft(4, '0')}')
              .join(' → '),
          style: const TextStyle(
              fontSize: 10, color: Color(0xFF78909C), fontFamily: 'RobotoMono'),
        ),
        trailing: FilledButton.tonal(
          onPressed:
              (connected && !_busy) ? () => _runComposite(name, ids) : null,
          child: const Text('Run all'),
        ),
      ),
    );
  }

  Widget _logView() {
    return Container(
      color: const Color(0xFF0B1420),
      child: Column(
        children: [
          Row(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 4, 4, 4),
                child: Text('LOG',
                    style: TextStyle(
                        color: Color(0xFF90CAF9),
                        fontSize: 10,
                        letterSpacing: 2)),
              ),
              const Spacer(),
              TextButton(
                onPressed:
                    _log.isEmpty ? null : () => setState(() => _log.clear()),
                child: const Text('Clear',
                    style: TextStyle(fontSize: 11, color: Color(0xFF90CAF9))),
              ),
            ],
          ),
          const Divider(height: 1, color: Color(0xFF1E3A5F)),
          Expanded(
            child: ListView.builder(
              controller: _logCtrl,
              padding: const EdgeInsets.all(6),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: TextStyle(
                  fontFamily: 'RobotoMono',
                  fontSize: 10,
                  color: _log[i].startsWith('!!')
                      ? const Color(0xFFFF8A80)
                      : _log[i].startsWith('---') || _log[i].startsWith('===')
                          ? const Color(0xFF00E676)
                          : _log[i].startsWith('>>>')
                              ? const Color(0xFFFFEB3B)
                              : const Color(0xFFCFD8DC),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
