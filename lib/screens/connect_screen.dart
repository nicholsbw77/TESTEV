import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import 'bms_clear_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController(text: '192.168.50.158');
  final _portController = TextEditingController(text: '3333');
  bool _connecting = false;
  bool _permissionsGranted = false;
  List<String> _connectionHistory = [];

  static const _kHistoryKey = 'wican_connection_history';
  static const _kLastHostKey = 'wican_last_host';
  static const _kLastPortKey = 'wican_last_port';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadConnectionHistory();
  }

  Future<void> _loadConnectionHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_kHistoryKey) ?? [];
    final lastHost = prefs.getString(_kLastHostKey);
    final lastPort = prefs.getString(_kLastPortKey);
    if (mounted) {
      setState(() {
        _connectionHistory = history;
        if (lastHost != null) _hostController.text = lastHost;
        if (lastPort != null) _portController.text = lastPort;
      });
    }
  }

  Future<void> _saveConnection(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    final entry = '$host:$port';
    final history = prefs.getStringList(_kHistoryKey) ?? [];
    history.remove(entry);
    history.insert(0, entry);
    if (history.length > 10) history.removeRange(10, history.length);
    await prefs.setStringList(_kHistoryKey, history);
    await prefs.setString(_kLastHostKey, host);
    await prefs.setString(_kLastPortKey, port.toString());
    if (mounted) setState(() => _connectionHistory = history);
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.locationWhenInUse,
      ].request();

      final allGranted = statuses.values.every(
        (s) => s.isGranted || s.isLimited,
      );

      if (mounted) {
        setState(() => _permissionsGranted = allGranted);
        if (!allGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bluetooth & Location permissions are required'),
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    } else {
      // iOS: WiFi works without special permissions; BT is disabled in UI
      if (mounted) setState(() => _permissionsGranted = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo / title
                const Text(
                  'TESTEV',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF00E676),
                    letterSpacing: 8,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tesla EV Battery Diagnostics',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF90CAF9),
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 48),

                // Status
                Text(
                  model.statusMessage,
                  style: TextStyle(
                    color: _connecting
                        ? const Color(0xFFFFEB3B)
                        : const Color(0xFF78909C),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // ── MeatPi WiCAN (WiFi) ──────────────────────────
                _sectionTitle('MeatPi WiCAN (WiFi)'),
                const SizedBox(height: 8),
                if (_connectionHistory.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16213E),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF1E3A5F)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        hint: const Text('Previous connections',
                            style: TextStyle(color: Color(0xFF546E7A), fontSize: 14)),
                        dropdownColor: const Color(0xFF16213E),
                        items: _connectionHistory.map((entry) {
                          return DropdownMenuItem(
                            value: entry,
                            child: Text(entry,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'RobotoMono',
                                    fontSize: 14)),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val == null) return;
                          final parts = val.split(':');
                          setState(() {
                            _hostController.text = parts[0];
                            if (parts.length > 1) _portController.text = parts[1];
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _textField(_hostController, 'IP Address'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: _textField(_portController, 'Port'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _connectButton(
                  'Connect via WiFi',
                  const Color(0xFF00E676),
                  _connecting
                      ? null
                      : () => _connectWifi(model),
                ),

                const SizedBox(height: 32),
                _divider(),
                const SizedBox(height: 32),

                // ── OBDLink MX+ (Bluetooth) ──────────────────────
                _sectionTitle('OBDLink MX+ (Bluetooth)'),
                const SizedBox(height: 12),
                _connectButton(
                  'Connect via Bluetooth',
                  const Color(0xFF2196F3),
                  _connecting ? null : () => _connectBluetooth(model),
                ),
                const SizedBox(height: 8),
                Text(
                  Platform.isIOS
                      ? 'Uses Apple MFi (ExternalAccessory) — pair the MX+ '
                          'in Settings → Bluetooth first'
                      : 'Auto-scans for paired OBDLink/ELM327 devices',
                  style: const TextStyle(
                    color: Color(0xFF78909C),
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _divider(),
                const SizedBox(height: 16),
                TextButton.icon(
                  icon: const Icon(Icons.build,
                      size: 16, color: Color(0xFFFFEB3B)),
                  label: const Text(
                    'BMS clear (advanced — no monitor needed)',
                    style: TextStyle(
                        color: Color(0xFFFFEB3B),
                        fontSize: 12,
                        letterSpacing: 1),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const BmsClearScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF90CAF9),
          fontSize: 14,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _textField(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(
        color: Colors.white,
        fontFamily: 'RobotoMono',
        fontSize: 14,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF546E7A)),
        filled: true,
        fillColor: const Color(0xFF16213E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF1E3A5F)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _connectButton(String text, Color color, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.15),
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.4)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: _connecting
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: color,
                ),
              )
            : Text(
                text,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
      ),
    );
  }

  Widget _divider() {
    return Row(
      children: [
        const Expanded(
          child: Divider(color: Color(0xFF1E3A5F)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
            ),
          ),
        ),
        const Expanded(
          child: Divider(color: Color(0xFF1E3A5F)),
        ),
      ],
    );
  }

  Future<void> _connectWifi(AppModel model) async {
    setState(() => _connecting = true);
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 3333;
    await _saveConnection(host, port);
    await model.connectSlcan(host, port);
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _connectBluetooth(AppModel model) async {
    setState(() => _connecting = true);
    await model.connectElm327(name: 'OBDLink');
    if (mounted) setState(() => _connecting = false);
  }
}
