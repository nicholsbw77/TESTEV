import 'can_frame.dart';
import 'pack_state.dart';

/// Adapter types supported by TESTEV
enum AdapterType {
  slcanWifi('MeatPi WiCAN (WiFi)', 'WiFi TCP → SLCAN'),
  elm327Bluetooth('OBDLink MX+ (Bluetooth)', 'Bluetooth SPP → ELM327');

  final String displayName;
  final String description;
  const AdapterType(this.displayName, this.description);
}

/// Abstract CAN adapter — both SLCAN and ELM327 implement this.
abstract class CanAdapter {
  final AdapterType type;
  bool connected = false;
  int frameCount = 0;
  int fps = 0;
  DateTime _fpsTime = DateTime.now();

  CanAdapter(this.type);

  /// Connect to the adapter hardware
  Future<void> connect();

  /// Disconnect
  Future<void> disconnect();

  /// Start receiving frames — calls onFrame for each decoded frame
  Future<void> startReceiving(void Function(CanFrame frame) onFrame);

  /// Track FPS
  void countFrame() {
    frameCount++;
    final now = DateTime.now();
    if (now.difference(_fpsTime).inMilliseconds >= 1000) {
      fps = frameCount;
      frameCount = 0;
      _fpsTime = now;
    }
  }
}

/// Dispatches decoded CAN frames into PackState fields
void dispatchFrame(PackState state, CanFrame frame) {
  switch (frame.id) {
    case 0x6F2:
      state.feed6F2(frame.data);
      break;
    case 0x102:
      if (!state.vehicleBus) state.feed102(frame.data);
      break;
    case 0x132:
      state.feed102(frame.data);
      break;
    case 0x202:
      if (!state.vehicleBus) state.feed202(frame.data);
      break;
    case 0x232:
      if (!state.vehicleBus) state.feed232(frame.data);
      break;
    case 0x302:
      if (!state.vehicleBus) state.feed302(frame.data);
      break;
    case 0x322:
      state.feed322(frame.data);
      break;
    case 0x332:
      state.feed332(frame.data);
      break;
    case 0x392:
      state.feed392(frame.data);
      break;
    case 0x3D2:
      state.feed3D2(frame.data);
      break;
    case 0x542:
      state.feed542(frame.data);
      break;
    case 0x552:
      state.feed552(frame.data);
      break;
    case 0x7E2:
      state.feed7E2(frame.data);
      break;
  }
}
