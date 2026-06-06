import 'package:flutter/material.dart';
import '../decoder/constants.dart';
import 'pack_state.dart';

enum AlertLevel { normal, warn, critical }

class ThresholdEvaluator {
  static Color cellColor(double voltage, double mean) {
    if (voltage.isNaN || mean.isNaN) return Colors.grey;
    if (voltage < cellVNominalMin) return Colors.red;
    if (voltage > cellVNominalMax) return Colors.red;

    final diffMv = (voltage - mean) * 1000;

    if (diffMv < -critMv) return Colors.red;
    if (diffMv < -warnMv) return Colors.yellow;
    if (diffMv > highMv) return Colors.blue;
    return Colors.green;
  }

  static Color spreadColor(double deltaMv) {
    if (deltaMv <= cellDeltaGreenMv) return Colors.green;
    if (deltaMv <= cellDeltaYellowMv) return Colors.yellow;
    return Colors.red;
  }

  static AlertLevel voltageAlert(double voltage) {
    if (voltage.isNaN) return AlertLevel.normal;
    if (voltage < cellVNominalMin || voltage > cellVNominalMax) {
      return AlertLevel.critical;
    }
    return AlertLevel.normal;
  }

  static AlertLevel tempAlert(double tempC) {
    if (tempC.isNaN) return AlertLevel.normal;
    if (tempC >= tempCritC) return AlertLevel.critical;
    if (tempC >= tempWarnC) return AlertLevel.warn;
    return AlertLevel.normal;
  }

  static AlertLevel isolationAlert(double kohm) {
    if (kohm.isNaN) return AlertLevel.normal;
    if (kohm < isolationCritKohm) return AlertLevel.critical;
    if (kohm < isolationWarnKohm) return AlertLevel.warn;
    return AlertLevel.normal;
  }

  static AlertLevel moduleSpreadAlert(double spreadMv) {
    if (spreadMv > spreadWarnMv) return AlertLevel.warn;
    return AlertLevel.normal;
  }

  static Color alertColor(AlertLevel level) {
    switch (level) {
      case AlertLevel.normal:
        return Colors.green;
      case AlertLevel.warn:
        return Colors.yellow;
      case AlertLevel.critical:
        return Colors.red;
    }
  }
}
