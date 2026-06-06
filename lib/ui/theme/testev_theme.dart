import 'package:flutter/material.dart';

final ThemeData testevTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0D1B2A),
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFF00E676),
    secondary: Color(0xFF90CAF9),
    surface: Color(0xFF16213E),
    error: Color(0xFFFF1744),
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
);
