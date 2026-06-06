import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../decoder/constants.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _wifiHostController = TextEditingController(text: '192.168.4.1');
  final _wifiPortController = TextEditingController(text: '3333');
  final _btNameController = TextEditingController(text: 'OBDLink');
  final _offsetController = TextEditingController();
  final _factorController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _wifiHostController.text = prefs.getString('wifi_host') ?? '192.168.4.1';
      _wifiPortController.text = prefs.getString('wifi_port') ?? '3333';
      _btNameController.text = prefs.getString('bt_name') ?? 'OBDLink';
      _offsetController.text = (prefs.getDouble('cell_offset') ?? 0.0).toString();
      _factorController.text = (prefs.getDouble('cell_factor') ?? 1.0).toString();
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wifi_host', _wifiHostController.text);
    await prefs.setString('wifi_port', _wifiPortController.text);
    await prefs.setString('bt_name', _btNameController.text);

    final offset = double.tryParse(_offsetController.text);
    final factor = double.tryParse(_factorController.text);
    if (offset != null) {
      await prefs.setDouble('cell_offset', offset);
      cellVoltageOffset = offset;
    }
    if (factor != null) {
      await prefs.setDouble('cell_factor', factor);
      cellVoltageFactor = factor;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Adapter Preferences',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _wifiHostController,
            decoration: const InputDecoration(
              labelText: 'Default WiFi IP',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _wifiPortController,
            decoration: const InputDecoration(
              labelText: 'Default WiFi Port',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _btNameController,
            decoration: const InputDecoration(
              labelText: 'Bluetooth Device Name Filter',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),

          const Text('Calibration',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Adjust if CAN-decoded voltages differ from DMM readings.\n'
            'voltage = (raw × scale + offset) × factor',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _offsetController,
            decoration: const InputDecoration(
              labelText: 'Cell Voltage Offset (V)',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _factorController,
            decoration: const InputDecoration(
              labelText: 'Cell Voltage Factor',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 24),

          ElevatedButton(
            onPressed: _saveSettings,
            child: const Text('Save Settings'),
          ),
          const SizedBox(height: 24),

          const Text('About',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TESTEV v2.0.0'),
                  Text('Tesla EV Battery Diagnostic Tool',
                      style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Sources: wk057 CAN Deciphering, EVTV, TMC community',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _wifiHostController.dispose();
    _wifiPortController.dispose();
    _btNameController.dispose();
    _offsetController.dispose();
    _factorController.dispose();
    super.dispose();
  }
}
