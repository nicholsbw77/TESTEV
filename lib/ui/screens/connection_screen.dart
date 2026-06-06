import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../transport/adapter_scanner.dart';
import '../../transport/adapter_transport.dart';
import '../../transport/wifi_tcp_transport.dart';
import '../../transport/bluetooth_spp_transport.dart';
import '../../transport/replay_transport.dart';
import '../../protocol/elm327_engine.dart';
import '../../protocol/raw_can_parser.dart';
import '../../decoder/decoder_engine.dart';
import '../../data/providers.dart';
import 'dashboard_screen.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _hostController = TextEditingController(text: '192.168.4.1');
  final _portController = TextEditingController(text: '3333');

  List<DetectedAdapter> _adapters = [];
  bool _scanning = false;
  String _status = '';
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _status = 'Scanning...';
    });
    try {
      _adapters = await AdapterScanner.scan();
      setState(() {
        _scanning = false;
        _status = 'Found ${_adapters.length} adapter(s)';
      });
    } catch (e) {
      setState(() {
        _scanning = false;
        _status = 'Scan error: $e';
      });
    }
  }

  Future<void> _connectWifi() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 3333;

    setState(() {
      _connecting = true;
      _status = 'Connecting to $host:$port...';
    });

    try {
      final transport = WifiTcpTransport(host: host, port: port);
      await transport.connect();

      final state = ref.read(packStateProvider);
      state.connected = true;
      state.vehicleBus = false;
      state.adapterType = transport.adapterName;
      state.modeLabel = 'can';

      final decoder = ref.read(decoderEngineProvider);
      final parser = RawCanParser();
      parser.frameStream.listen((frame) => decoder.dispatch(frame));
      transport.dataStream.listen((data) => parser.feedBytes(data));

      ref.read(connectionStateProvider.notifier).state = true;

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DashboardScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _connecting = false;
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _connectBluetooth(DetectedAdapter adapter) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting to ${adapter.name}...';
    });

    try {
      final transport = BluetoothSppTransport(
        deviceAddress: adapter.address,
        deviceName: adapter.name,
      );
      await transport.connect();

      final state = ref.read(packStateProvider);
      state.connected = true;
      state.vehicleBus = true;
      state.adapterType = adapter.name;
      state.modeLabel = 'can';

      final decoder = ref.read(decoderEngineProvider);
      final engine = Elm327Engine();

      engine.frameStream.listen((frame) => decoder.dispatch(frame));
      transport.dataStream.listen((data) => engine.feedBytes(data));

      // Send init sequence
      final initCmds = engine.buildInitSequence(stfapFilters: [
        '332,7FF', '392,7FF', '6F2,7FF', '7E2,7FF',
      ]);
      for (final cmd in initCmds) {
        await transport.send(cmd);
        await Future.delayed(const Duration(milliseconds: 300));
      }
      engine.markInitialized();

      ref.read(connectionStateProvider.notifier).state = true;

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DashboardScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _connecting = false;
        _status = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final btAdapters =
        _adapters.where((a) => a.transportType == 'bluetooth').toList();

    return Scaffold(
      appBar: AppBar(title: const Text('TESTEV — Connect')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (_scanning || _connecting)
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    if (_scanning || _connecting) const SizedBox(width: 12),
                    Expanded(child: Text(_status)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // WiFi section
            const Text('WiFi (MeatPi / WiCAN)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: 'IP Address',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _connecting ? null : _connectWifi,
              icon: const Icon(Icons.wifi),
              label: const Text('Connect WiFi'),
            ),
            const SizedBox(height: 24),

            // Bluetooth section
            if (Platform.isAndroid) ...[
              Row(
                children: [
                  const Expanded(
                    child: Text('Bluetooth (OBDLink)',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: _scanning ? null : _scan,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (btAdapters.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No Bluetooth adapters found.\n'
                        'Pair your OBDLink in system Bluetooth settings first.'),
                  ),
                ),
              ...btAdapters.map((a) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(a.name),
                      subtitle: Text(a.address),
                      trailing: ElevatedButton(
                        onPressed:
                            _connecting ? null : () => _connectBluetooth(a),
                        child: const Text('Connect'),
                      ),
                    ),
                  )),
              const SizedBox(height: 24),
            ],

            // Replay section
            const Text('Replay',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _connecting ? null : () {
                // TODO: File picker for replay log
                setState(() => _status = 'Replay file picker not yet implemented');
              },
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Load Replay File'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }
}
