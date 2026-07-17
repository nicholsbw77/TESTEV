import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'can/pack_state.dart';
import 'can/adapter_base.dart';
import 'can/slcan_adapter.dart';
import 'can/elm327_adapter.dart';
import 'can/elm327_base.dart';
import 'can/elm327_ea_adapter.dart';
import 'screens/dashboard_screen.dart';
import 'screens/connect_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppModel(),
      child: const TESTEVApp(),
    ),
  );
}

/// App-wide state: pack data + adapter connection
class AppModel extends ChangeNotifier {
  final PackState state = PackState();
  CanAdapter? _adapter;
  String statusMessage = 'Not connected';
  bool get isConnected => _adapter?.connected ?? false;

  Future<void> connectSlcan(String host, int port) async {
    await _disconnect();
    final adapter = SlcanAdapter(host: host, port: port);
    _adapter = adapter;
    state.adapterType = 'MeatPi WiCAN';
    state.vehicleBus = false;

    try {
      statusMessage = 'Connecting to $host:$port...';
      notifyListeners();

      await adapter.connect();
      statusMessage = 'Connected — receiving frames';
      state.connected = true;
      notifyListeners();

      WakelockPlus.enable();  // Keep screen on

      await adapter.startReceiving((frame) {
        dispatchFrame(state, frame);
        state.fps = adapter.fps;
        // Throttle UI updates to ~4Hz
        if (DateTime.now().millisecondsSinceEpoch % 250 < 50) {
          notifyListeners();
        }
      });
    } catch (e) {
      statusMessage = 'Error: $e';
      state.connected = false;
      notifyListeners();
    }
  }

  Future<void> connectElm327({String? address, String? name}) async {
    await _disconnect();
    // iOS talks to the MFi-certified MX+ via ExternalAccessory;
    // Android uses classic Bluetooth SPP.
    final Elm327Base adapter = Platform.isIOS
        ? Elm327EaAdapter(
            onStatus: (msg) {
              statusMessage = msg;
              notifyListeners();
            },
          )
        : Elm327Adapter(
            deviceAddress: address,
            deviceName: name,
            onStatus: (msg) {
              statusMessage = msg;
              notifyListeners();
            },
          );
    _adapter = adapter;
    state.adapterType = 'OBDLink MX+';
    state.vehicleBus = true;

    try {
      await adapter.connect();
      state.connected = true;
      notifyListeners();

      WakelockPlus.enable();

      await adapter.startReceiving((frame) {
        dispatchFrame(state, frame);
        state.fps = adapter.fps;
        if (DateTime.now().millisecondsSinceEpoch % 250 < 50) {
          notifyListeners();
        }
      });
    } catch (e) {
      statusMessage = 'Error: $e';
      state.connected = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async => _disconnect();

  Future<void> _disconnect() async {
    if (_adapter != null) {
      await _adapter!.disconnect();
      _adapter = null;
    }
    state.connected = false;
    state.vehicleBus = false;
    statusMessage = 'Disconnected';
    WakelockPlus.disable();
    notifyListeners();
  }
}

class TESTEVApp extends StatelessWidget {
  const TESTEVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TESTEV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1B2A),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF00E676),
          secondary: const Color(0xFF90CAF9),
          surface: const Color(0xFF16213E),
          error: const Color(0xFFFF1744),
        ),
        fontFamily: 'RobotoMono',
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D1B2A),
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF16213E),
          elevation: 2,
          margin: EdgeInsets.all(4),
        ),
      ),
      home: Consumer<AppModel>(
        builder: (context, model, _) {
          if (model.isConnected) {
            return const DashboardScreen();
          }
          return const ConnectScreen();
        },
      ),
    );
  }
}
