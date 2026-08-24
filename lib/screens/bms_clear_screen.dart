import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../bms/routines.dart';
import '../bms/bms_uds_client.dart';
import '../can/slcan_adapter.dart';

/// BMS DTC-clear screen. Talks to a MeatPi WiCAN in **native SLCAN mode**
/// over WiFi TCP — the only adapter path this pack's UDS stack has ever
/// actually been observed to work over (per the bench GUI's Python).
///
/// OBDLink MX+ was removed as an option: an ELM327 physically cannot do
/// UDS/sending on this pack (the Python code raises on that path).
/// OBDLink remains the right choice for the dashboard's monitor mode.
class BmsClearScreen extends StatefulWidget {
  const BmsClearScreen({super.key});

  @override
  State<BmsClearScreen> createState() => _BmsClearScreenState();
}

class _BmsClearScreenState extends State<BmsClearScreen> {
  SlcanAdapter? _adapter;
  BmsUdsClient? _uds;
  final List<String> _log = [];
  final ScrollController _logCtrl = ScrollController();

  String _status = 'Not connected';
  bool _busy = false;
  bool _sessionOpen = false;

  final _hostController = TextEditingController(text: '192.168.80.1');
  final _portController = TextEditingController(text: '3333');

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
      _hostController.text = prefs.getString(_kLastHostKey) ?? _hostController.text;
      _portController.text = prefs.getString(_kLastPortKey) ?? _portController.text;
    });
  }

  Future<void> _saveEndpoint(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastHostKey, host);
    await prefs.setString(_kLastPortKey, port.toString());
  }

  @override
  void dispose() {
    _teardown();
    _logCtrl.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  // ── connection lifecycle ──────────────────────────────────────────────

  Future<void> _connect() async {
    if (_adapter != null) return;
    final monitorOn = context.read<AppModel>().isConnected;
    if (monitorOn) {
      _snack('Disconnect the dashboard monitor first '
          '(WiCAN only accepts one TCP client at a time).');
      return;
    }
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 3333;
    if (host.isEmpty) {
      _snack('WiCAN host is required.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Connecting to $host:$port…';
    });
    _appendLog('--- Connecting to $host:$port (SLCAN mode) ---');
    try {
      await _saveEndpoint(host, port);
      final adapter = SlcanAdapter(host: host, port: port);
      await adapter.connect();
      _appendLog('SLCAN open OK — C\\r S6\\r O\\r sent');
      final uds = BmsUdsClient(adapter, onLog: _appendLog)..open();
      _adapter = adapter;
      _uds = uds;
      setState(() => _status = 'Connected — session/security not yet opened');
    } catch (e) {
      _appendLog('!! connect failed: $e');
      _appendLog('   Tip: WiCAN protocol must be "slcan" (not "ELM327").');
      setState(() => _status = 'Connect failed: $e');
      await _teardown();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _teardown() async {
    try {
      _uds?.stopKeepAlive();
      await _uds?.close();
    } catch (_) {}
    _uds = null;
    try {
      await _adapter?.disconnect();
    } catch (_) {}
    _adapter = null;
    _sessionOpen = false;
    if (mounted) setState(() => _status = 'Disconnected');
  }

  Future<void> _openSession() async {
    final uds = _uds;
    if (uds == null) return;
    _appendLog('--- Opening extended session + SecurityAccess ---');
    final sess = await uds.startSession(0x03);
    if (!sess) {
      setState(() {
        _sessionOpen = false;
        _status = 'Session 0x03 rejected';
      });
      return;
    }
    final sec = await uds.unlockSecurity();
    setState(() {
      _sessionOpen = sec;
      _status = sec ? 'Session + Security OK' : 'SecurityAccess failed';
    });
    if (sec) {
      uds.startKeepAlive();
      _appendLog('--- TesterPresent keepalive started (4.5s) ---');
    }
  }

  // ── command execution ─────────────────────────────────────────────────

  Future<void> _runRoutine(Routine r) async {
    if (_uds == null) {
      _snack('Connect first.');
      return;
    }
    if (_busy) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Run ${r.label}?'),
        content: Text(
          'Sends routineControl start ${r.hexId} on 0x602.\n\n'
          'Only run this after the underlying fault has been repaired.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
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
      _appendLog('--- ${r.label} (${r.hexId}) ---');
      final res = await _uds!.runRoutine(r.routineId);
      _appendLog('    → ${res.label}');
      setState(() => _status = '${r.label}: ${res.label}');
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Run composite: $name?'),
        content: Text(
          'Runs ${routines.length} routines in order:\n\n'
          '${routines.map((r) => '  • ${r.hexId}  ${r.label}').join('\n')}\n\n'
          'Only run after repairing the underlying fault.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
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
        _appendLog('--- ${r.label} (${r.hexId}) ---');
        final res = await _uds!.runRoutine(r.routineId);
        _appendLog('    → ${res.label}');
        await Future.delayed(const Duration(milliseconds: 250));
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
    final canRun = connected && !_busy;

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
          _wicanRow(connected),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
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
                      width: 14,
                      height: 14,
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

  Widget _warningBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0x33FF1744),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: const Text(
        'These commands write to the BMS on Model S/X (2013-era) packs. '
        'Only run each after you have REPAIRED the underlying fault. '
        'Requires a MeatPi WiCAN in native SLCAN mode (not ELM emulator).',
        style: TextStyle(color: Color(0xFFFFCDD2), fontSize: 11),
      ),
    );
  }

  Widget _wicanRow(bool connected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          const Text('WiCAN:',
              style: TextStyle(
                  color: Color(0xFF90CAF9),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: _textField(_hostController, 'IP address', !connected && !_busy),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: _textField(_portController, 'port', !connected && !_busy),
          ),
        ],
      ),
    );
  }

  Widget _textField(TextEditingController ctrl, String hint, bool enabled) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      style: const TextStyle(
        color: Colors.white,
        fontFamily: 'RobotoMono',
        fontSize: 13,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF546E7A), fontSize: 12),
        filled: true,
        fillColor: const Color(0xFF16213E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF1E3A5F)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    );
  }

  Widget _routineList(bool canRun) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final r in kRoutines) _routineTile(r, canRun),
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
          _compositeTile(entry.key, entry.value, canRun),
      ],
    );
  }

  Widget _routineTile(Routine r, bool canRun) {
    return Card(
      child: ListTile(
        dense: true,
        title: Text(r.label,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE0E0E0))),
        subtitle: Text(
          '${r.hexId}  •  req 0x602'
          '${r.faults.isEmpty ? '' : '\n${r.faults.join(", ")}'}',
          style: const TextStyle(
              fontSize: 10, color: Color(0xFF78909C), fontFamily: 'RobotoMono'),
        ),
        trailing: FilledButton.tonal(
          onPressed: canRun ? () => _runRoutine(r) : null,
          child: const Text('Run'),
        ),
      ),
    );
  }

  Widget _compositeTile(String name, List<int> ids, bool canRun) {
    return Card(
      child: ListTile(
        dense: true,
        title: Text(name,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE0E0E0))),
        subtitle: Text(
          ids
              .map((id) =>
                  '0x${id.toRadixString(16).toUpperCase().padLeft(4, '0')}')
              .join(' → '),
          style: const TextStyle(
              fontSize: 10, color: Color(0xFF78909C), fontFamily: 'RobotoMono'),
        ),
        trailing: FilledButton.tonal(
          onPressed:
              canRun ? () => _runComposite(name, ids) : null,
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
