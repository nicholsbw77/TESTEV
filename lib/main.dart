import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'ui/theme/testev_theme.dart';
import 'ui/screens/connection_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  WakelockPlus.enable();

  runApp(const ProviderScope(child: TESTEVApp()));
}

class TESTEVApp extends StatelessWidget {
  const TESTEVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TESTEV',
      debugShowCheckedModeBanner: false,
      theme: testevTheme,
      home: const ConnectionScreen(),
    );
  }
}
