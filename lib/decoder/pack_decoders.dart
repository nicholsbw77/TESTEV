import 'dart:typed_data';
import 'constants.dart';

class PackVoltCurrResult {
  final double packVoltage;
  final double packCurrent;
  final double? negTerminalTempC;

  const PackVoltCurrResult({
    required this.packVoltage,
    required this.packCurrent,
    this.negTerminalTempC,
  });
}

class SocResult {
  final double socPercent;
  final double kwhDischarged;
  final double kwhCharged;

  const SocResult({
    required this.socPercent,
    required this.kwhDischarged,
    required this.kwhCharged,
  });
}

class ContactorResult {
  final String state;
  final int rawByte0;

  const ContactorResult({required this.state, required this.rawByte0});
}

class IsolationResult {
  final double isolationKohm;

  const IsolationResult({required this.isolationKohm});
}

PackVoltCurrResult? decode0x102(Uint8List data) {
  if (data.length < 6) return null;

  final packV = ((data[0] << 8) | data[1]) * packVoltageScale;

  int rawI = ((data[2] & 0x7F) << 8) | data[3];
  if (data[2] & 0x80 != 0) rawI -= 0x8000;
  final packI = rawI * packCurrentScale + packCurrentOffset;

  double? negTemp;
  if (data.length >= 8) {
    final rawTemp = data[6] | ((data[7] & 0x07) << 8);
    negTemp = rawTemp * 0.1 - 40.0;
  }

  return PackVoltCurrResult(
    packVoltage: packV,
    packCurrent: packI,
    negTerminalTempC: negTemp,
  );
}

SocResult? decode0x302(Uint8List data) {
  if (data.length < 8) return null;

  final socRaw = ((data[0] & 0x03) << 8) | data[1];
  final soc = socRaw * 0.1;
  final kwhOut = ((data[2] << 8) | data[3]) * kwhScale;
  final kwhIn = ((data[4] << 8) | data[5]) * kwhScale;

  return SocResult(
    socPercent: soc,
    kwhDischarged: kwhOut,
    kwhCharged: kwhIn,
  );
}

ContactorResult? decode0x312(Uint8List data) {
  if (data.isEmpty) return null;
  final code = data[0] & 0x0F;
  final state = contactorStates[code] ?? 'UNKNOWN(0x${code.toRadixString(16).padLeft(2, '0')})';
  return ContactorResult(state: state, rawByte0: data[0]);
}

IsolationResult? decode0x322(Uint8List data) {
  if (data.length < 2) return null;
  final kohm = ((data[0] << 8) | data[1]) * 1.0;
  return IsolationResult(isolationKohm: kohm);
}
