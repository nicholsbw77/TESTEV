import 'dart:async';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:ea_accessory/ea_accessory.dart';

import 'adapter_base.dart';
import 'elm327_base.dart';

/// ELM327/STN over Apple's ExternalAccessory framework — the iOS path for
/// the MFi-certified OBDLink MX+.
///
/// The accessory must be paired in Settings → Bluetooth first. iOS only lets
/// an app open a session for protocol strings declared in Info.plist
/// (UISupportedExternalAccessoryProtocols). OBD Solutions doesn't publish
/// theirs, so this adapter discovers what the MX+ actually advertises at
/// runtime: if none of the declared strings match, it fails with a message
/// showing the real strings so they can be added to Info.plist (a one-time,
/// one-line fix — see ios/README_MFI.md).
class Elm327EaAdapter extends Elm327Base {
  Elm327EaAdapter({super.onStatus}) : super(AdapterType.elm327Bluetooth);

  String? accessoryName;
  String? protocolUsed;

  @override
  Future<void> openTransport() async {
    onStatus?.call('Looking for MFi accessories...');
    final accessories = await EaAccessory.listAccessories();
    final declared = await EaAccessory.declaredProtocols();

    // DEBUG-CAPTURE: dump everything iOS surfaced so we can pick the right
    // UISupportedExternalAccessoryProtocols string. Remove after fix.
    dev.log('declared protocols: $declared', name: 'EACAP');
    dev.log('accessory count: ${accessories.length}', name: 'EACAP');
    for (final a in accessories) {
      dev.log('name="${a.name}" mfr="${a.manufacturer}" '
          'model="${a.modelNumber}" protocols=${a.protocols}',
          name: 'EACAP');
    }

    if (accessories.isEmpty) {
      throw Exception(
          'No MFi accessory connected.\n'
          'Pair the OBDLink MX+ in Settings → Bluetooth (hold its button '
          'until it blinks), then try again.');
    }

    // Prefer accessories that look like an OBDLink, then any accessory
    // advertising a protocol we declared in Info.plist.
    final ordered = [...accessories]..sort((a, b) {
        int score(EaAccessoryInfo x) =>
            ('${x.name} ${x.manufacturer}'.toLowerCase().contains('obd'))
                ? 0
                : 1;
        return score(a) - score(b);
      });

    for (final acc in ordered) {
      for (final proto in acc.protocols) {
        if (declared.contains(proto)) {
          onStatus?.call('Opening MFi session with ${acc.name} ($proto)...');
          accessoryName = await EaAccessory.connect(proto);
          protocolUsed = proto;
          return;
        }
      }
    }

    // Nothing matched: surface the real protocol strings so the fix is obvious.
    final seen = ordered
        .map((a) => '${a.name}: ${a.protocols.join(", ")}')
        .join('\n');
    throw Exception(
        'Accessory found, but none of its protocol strings are declared in '
        'Info.plist.\nAdvertised:\n$seen\n\nAdd the OBDLink string to '
        'UISupportedExternalAccessoryProtocols in ios/Runner/Info.plist and '
        'rebuild (see ios/README_MFI.md).');
  }

  @override
  Future<void> closeTransport() async {
    try {
      await EaAccessory.disconnect();
    } catch (_) {}
  }

  @override
  void writeBytes(List<int> bytes) {
    // Fire-and-forget: ELM commands are tiny and the native side queues them.
    unawaited(EaAccessory.write(Uint8List.fromList(bytes)));
  }

  @override
  Stream<List<int>> inputStream() => EaAccessory.input;
}
