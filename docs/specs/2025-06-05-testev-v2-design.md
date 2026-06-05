# TESTEV v2 — Tesla EV Diagnostic App Design Specification

**Date:** 2025-06-05
**Status:** Draft — pending user approval
**Scope:** Sub-project 1 — CAN Protocol Decoder + Transport + Data Layer + Dashboard UI
**Target vehicle:** Model S (current firmware), extensible to other generations later
**Platform:** Android + iOS (Flutter + native platform channels)

---

## 1. Overview

TESTEV v2 is a from-scratch rebuild of the Tesla EV Battery Diagnostic Tool. It connects to a Tesla Model S via OBD adapters (OBDLink MX/LX over Bluetooth, MeatPi/WiCAN over WiFi) and provides real-time battery diagnostics with a customizable live dashboard.

The app decodes CAN bus frames from the vehicle's PT_CAN bus (500 kbit/s), extracts battery pack data (96 cell voltages, 32 temperatures, pack voltage/current/SOC, contactor state, isolation resistance, thermal system data), and displays it through interactive dashboard widgets.

### What this build covers

- Two transport paths: Bluetooth SPP (OBDLink) and WiFi TCP (MeatPi/WiCAN)
- CAN frame decoder for Model S BMS messages (0x6F2, 0x102, 0x302, 0x312, 0x322)
- Reactive data model holding full pack state
- Customizable dashboard with draggable/resizable widgets
- Session logging to CSV (cross-compatible with existing Python tool format)
- Replay mode for development and testing without hardware

### What this build does NOT cover

- Model 3/Y/refreshed S/X decoder profiles (future sub-projects)
- Direct BMB UART access at 612500 baud (stays as the Python bench tool)
- USB serial transport (deferred — not needed for current hardware)
- UDS write commands / active diagnostics (read-only for v1)
- Vehicle data beyond BMS (speed, tire PSI, power usage — future sub-project using the non-BMS CAN IDs observed in captures: 0x358, 0x53A, 0x25C, 0x71C, 0x00E, 0x278)

---

## 2. Architecture

Five layers, each with a single responsibility. Dependencies flow downward only.

```
┌─────────────────────────────────────────────┐
│                  UI Layer                    │
│         (Flutter widgets, dashboard)         │
├─────────────────────────────────────────────┤
│                 Data Layer                   │
│   (PackState, reactive streams, CSV logger)  │
├─────────────────────────────────────────────┤
│                Decoder Layer                 │
│    (CAN frame → signals, mux accumulator)    │
├─────────────────────────────────────────────┤
│               Protocol Layer                 │
│   (ELM327 AT engine, raw CAN frame parser)   │
├─────────────────────────────────────────────┤
│               Transport Layer                │
│  (Bluetooth SPP native, WiFi TCP pure Dart)  │
└─────────────────────────────────────────────┘
```

Each layer is a Dart package (or native module for transport) that can be tested independently. The decoder can be tested against recorded CAN logs with zero hardware. The UI can be tested against replay data with zero adapter connection.

---

## 3. Transport Layer

### 3.1 Unified interface

All transports implement this Dart interface:

```dart
abstract class AdapterTransport {
  Future<void> connect();
  Future<void> disconnect();
  Stream<Uint8List> get dataStream;      // raw bytes from adapter
  Future<void> send(Uint8List data);      // raw bytes to adapter
  bool get isConnected;
  String get adapterName;                 // "OBDLink MX+", "WiCAN", etc.
  TransportType get type;                 // bluetooth, wifi, replay
}
```

### 3.2 Bluetooth SPP (OBDLink MX/LX, generic ELM327)

**Android (Kotlin):** Uses `BluetoothSocket` with SPP UUID `00001101-0000-1000-8000-00805F9B34FB`. Handles device discovery, pairing, and connection. Exposes bidirectional byte stream to Dart via:
- `MethodChannel('testev/bluetooth')` for connect/disconnect/send commands
- `EventChannel('testev/bluetooth/data')` for incoming byte stream

**iOS (Swift):** OBDLink devices are MFi-certified, so uses `ExternalAccessory` framework. For generic ELM327 BLE adapters, uses `CoreBluetooth` with UART service UUID. Same channel pattern as Android.

**Native code scope:** ~200-300 lines per platform. Thin wrapper — no protocol logic in native code.

### 3.3 WiFi TCP (MeatPi/WiCAN)

**Pure Dart** using `dart:io Socket`. MeatPi creates a WiFi AP; the phone connects to it and opens a TCP socket to the device's IP (typically `192.168.4.1:3333` for MeatPi, configurable).

MeatPi sends raw CAN frames in one of two formats:
- **SLCAN:** `t1026F2186DC6A3C16641A\r` (ASCII, 't' prefix, ID, length, hex data)
- **Native binary:** Header + arbitration ID (4 bytes) + data length (1 byte) + data

The protocol layer handles format detection.

No native code needed for this transport.

### 3.4 Replay transport

Pure Dart. Reads a log file (ELM327 ATMA format or python-can `.log` format, matching the parsers in the existing `replay.py`) and emits frames at original timing ratios with adjustable speed multiplier. Loops continuously.

Used for dashboard development, testing, and demo mode.

### 3.5 Adapter auto-detection

Connection screen scans for:
- **Bluetooth:** Devices matching name patterns: `OBDLink*`, `ELM327*`, `STN*`, `OBDII*`
- **WiFi:** Known SSIDs: `WiCAN*`, `MeatPi*`, `ESP32_CAN*`

Presents detected adapters with the correct transport pre-selected. User can also manually enter connection details.

---

## 4. Protocol Layer

### 4.1 ELM327/AT protocol engine

Handles initialization and frame monitoring for OBDLink and ELM327 adapters. Ported directly from the `ELM327Bus` class in `adapter.py`.

**Initialization sequence:**
```
ATZ      → reset
ATE0     → echo off
ATL0     → linefeeds off
ATH1     → show headers (include arbitration ID)
ATCAF0   → CAN auto-formatting off
ATCSM1   → CAN silent monitoring on
ATMA     → monitor all CAN frames
```

**Frame parsing:** Uses the same regex pattern from `adapter.py`:
```
([0-9A-Fa-f]{3,8})\s+([0-9A-Fa-f]{2}(?:\s+[0-9A-Fa-f]{2}){0,7})
```

Extracts arbitration ID and data bytes from each line in the serial stream. Emits `CanFrame` objects into a unified stream.

**Frame rate tracking:** Maintains a rolling frames/second counter (same logic as `ELM327Bus._frame_rate`). Exposed to the UI for connection health monitoring.

**Error recovery:** If the stream stalls for >2 seconds, sends `ATMA\r` to restart monitoring. If that fails, sends full re-init sequence.

### 4.2 Raw CAN frame parser

Handles MeatPi/WiCAN WiFi data. Detects SLCAN vs binary format on first received data, then parses accordingly into the same `CanFrame` stream.

### 4.3 Shared CanFrame model

```dart
class CanFrame {
  final int arbitrationId;     // 11-bit or 29-bit
  final Uint8List data;        // 0-8 bytes
  final double timestamp;      // seconds since epoch
  final bool isExtended;       // true if 29-bit ID
}
```

Both protocol engines emit this same type. The decoder layer doesn't know or care which transport or protocol produced the frame.

---

## 5. Decoder Layer

### 5.1 Overview

Pure Dart. Consumes a `Stream<CanFrame>` and emits decoded signal values. Ported directly from `decode.py` and `config.py` — proven logic, not new code.

### 5.2 Known BMS CAN IDs

From `config.py`, all BMS-originated IDs end in `0x_2`:

```
Primary (decoded in v1):
  0x6F2  — Cell voltages + temperatures (multiplexed, 32 frames/sweep)
  0x102  — Pack voltage, current, negative terminal temperature
  0x302  — State of charge, kWh counters
  0x312  — Contactor state
  0x322  — Isolation resistance

Stub-decoded (log raw hex, decode in future):
  0x202, 0x212, 0x222, 0x232, 0x242,
  0x332, 0x342, 0x352, 0x362, 0x372,
  0x382, 0x3A2, 0x3B2, 0x3C2, 0x3D2,
  0x3E2, 0x3F2, 0x402, 0x412, 0x502,
  0x512, 0x532, 0x542, 0x552, 0x562,
  0x5D2, 0x7E2
```

UDS addressing (future active diagnostics): Request 0x792, Response 0x793.

### 5.3 Decoder: 0x6F2 — Cell voltages and temperatures

Ported from `CellFrameBuffer` in `decode.py`. This is the most complex decoder.

**Message structure:**
- Byte 0: Mux index (0x00–0x1F, 32 total)
- Bytes 1–7: 56-bit payload, little-endian
- Payload contains 4 × 14-bit values

**Mux ranges:**
- 0x00–0x17 (24 frames × 4 = 96): Cell voltages, unsigned 14-bit
  - `voltage = raw * 0.000305` (V/LSB, from wk057 CAN Deciphering v0.1)
  - Calibration: `voltage = (raw * CELL_VOLTAGE_SCALE + CELL_VOLTAGE_OFFSET) * CELL_VOLTAGE_FACTOR`
  - Default: OFFSET=0.0, FACTOR=1.0 (adjustable in settings for DMM calibration)
- 0x18–0x1F (8 frames × 4 = 32): Temperatures, signed 14-bit (two's complement)
  - Sign extension: if bit 13 set, `value = value - 0x4000`
  - `temp_c = signed_raw * 0.0122` (°C/LSB)

**Accumulator:** Tracks which of the 32 mux indices have been seen. Emits a complete snapshot when all 32 arrive. Resets the seen-set after each complete sweep. Provides `completion_pct` for the UI progress indicator.

**Timeout recovery:** If a full sweep hasn't completed within 1.0 seconds (`CAN_SWEEP_TIMEOUT_S`), emit a partial snapshot with whatever data is available.

**Temperature filtering:** Raw temp values outside the range -40°C to +120°C are treated as invalid (the CSV captures show garbage values like -1493°C in some temp slots — these are filtered to NaN).

### 5.4 Decoder: 0x102 — Pack voltage, current, terminal temp

Ported from `decode_0x102` in `decode.py`.

```
Bytes 0-1: Pack voltage (unsigned, big-endian, scale 0.01 V)
Bytes 2-3: Pack current (signed 15-bit, scale 0.1 A, offset -1000 A)
           Bit 15 of byte 2 is sign bit.
           raw = ((data[2] & 0x7F) << 8) | data[3]
           if data[2] & 0x80: raw -= 0x8000
           current = raw * 0.1 + (-1000.0)
Bytes 6-7: Negative terminal temp (8-byte frames only)
           raw = data[6] | ((data[7] & 0x07) << 8)
           temp_c = raw * 0.1 - 40.0
```

Message rate: ~100 Hz. The data layer samples at 2 Hz for the UI.

### 5.5 Decoder: 0x302 — SOC and energy counters

Ported from `decode_0x302` in `decode.py`.

```
Bytes 0-1: SOC (10-bit, scale 0.1%)
           soc = ((data[0] & 0x03) << 8 | data[1]) * 0.1
Bytes 2-3: kWh discharged (scale 0.01 kWh)
Bytes 4-5: kWh charged (scale 0.01 kWh)
```

Note from source: "exact byte layout varies between firmware revisions — values are community-derived best-effort." The raw hex is always logged alongside decoded values for verification.

### 5.6 Decoder: 0x312 — Contactor state

```
Byte 0 low nibble:
  0x00 = OPEN
  0x01 = PRECHARGE
  0x03 = CLOSED
  0x04 = FAULT
```

### 5.7 Decoder: 0x322 — Isolation resistance

```
Bytes 0-1: Isolation in kΩ (unsigned, big-endian, scale TBC on bench)
Good: >500 kΩ    Warning: <500 kΩ    Critical: <100 kΩ
```

### 5.8 Dispatch and unknown frames

A dispatch map routes each CAN ID to its decoder function. Unknown IDs within the BMS ID set (`CAN_BMS_ALL_IDS`) are logged as raw hex for future decoding. IDs outside the BMS set are silently dropped (until the vehicle data sub-project adds decoders for speed, PSI, etc.).

### 5.9 Extensibility

Each decoder is a standalone function with the signature `Map<String, dynamic> decode(Uint8List data)`. Adding a new CAN ID decoder means writing one function and adding one entry to the dispatch map. When Model 3/Y support is added, the decoder profiles become JSON-driven with per-generation CAN databases, but for the Model S first build, the decoders are hardcoded Dart (ported directly from proven Python).

---

## 6. Data Layer

### 6.1 PackState model

Central reactive state object. All decoded values flow here; the UI subscribes to slices of it. Ported from the `PackState` referenced in `csv_logger.py`.

```dart
class PackState {
  // Timestamps
  double timestamp;
  String modeLabel;              // "can", "replay"

  // Pack-level (from 0x102)
  double packVoltage;            // V
  double packCurrent;            // A
  double negTerminalTempC;       // °C

  // SOC (from 0x302)
  double socPercent;
  double kwhCharged;
  double kwhDischarged;

  // Contactor (from 0x312)
  String contactorState;         // "OPEN", "PRECHARGE", "CLOSED", "FAULT"

  // Isolation (from 0x322)
  double isolationKohm;

  // Cells (from 0x6F2)
  List<double> cellVoltages;     // length 96, NaN for unseen
  List<(double, double)> moduleTemps;  // length 16, (t1, t2) per module
  List<double> moduleVoltages;   // length 16, sum of 6 cells each

  // Derived
  double get cellVMin;
  double get cellVMax;
  double get cellVDelta;
  double get cellVMean;
  double get sweepCompletionPct;

  // Alerts
  List<Alert> unexpectedAlerts;
}
```

### 6.2 Threshold evaluation

Color-coding logic applied in the data layer, not the UI. Ported from `config.py`:

**Cell voltage relative to mean:**
- Green: within ±6 mV of mean
- Yellow (low): 6–12 mV below mean (WARN_MV)
- Red (low): >12 mV below mean (CRIT_MV)
- Blue (high): >6 mV above mean (HIGH_MV)

**Pack spread:**
- Green: <20 mV (CELL_DELTA_GREEN_MV)
- Yellow: 20–50 mV (CELL_DELTA_YELLOW_MV)
- Red: >100 mV (CELL_DELTA_RED_MV)

**Absolute voltage:**
- Critical low: <3.0 V (CELL_V_NOMINAL_MIN)
- Critical high: >4.20 V (CELL_V_NOMINAL_MAX)
- Balance recommended: >4.15 V (CELL_V_BALANCE_HIGH)

**Temperature:**
- Warning: >40°C (TEMP_WARN_C)
- Critical: >50°C (TEMP_CRIT_C)

**Isolation:**
- Warning: <500 kΩ
- Critical: <100 kΩ

**Intra-module spread:**
- Warning: >15 mV (SPREAD_WARN_MV)

### 6.3 Session logging

Ported from `csv_logger.py`. Writes CSV with the same header structure for cross-compatibility with the Python bench tool:

```
timestamp, source, pack_v, pack_i, soc_pct,
isolation_kohm, kwh_charged, kwh_discharged,
contactor_state, neg_term_temp_c,
cell_v_min, cell_v_max, cell_v_delta,
balance_active,
cell_01 .. cell_96,
mod_01_v .. mod_16_v,
mod_01_t1 .. mod_16_t1,
mod_01_t2 .. mod_16_t2,
alerts
```

Logs at 2 Hz (GUI_REFRESH_HZ from config). Session info summary file written on stop (duration, start/end voltage, SOC, cell stats).

Files stored in app-local storage, exportable via share sheet.

### 6.4 Replay mode

The data layer accepts a `ReplayTransport` that reads a log file and feeds it through the protocol and decoder layers at configurable speed. The rest of the app — dashboard, logging, everything — works identically whether live or replaying.

Supported log formats (from `replay.py`):
- ELM327 ATMA output (the format the existing captures use)
- Python-can `.log` format
- Raw CSV format matching `tesla_raw.csv` (timestamp, can_id, payload_hex)

---

## 7. UI Layer

### 7.1 Navigation structure

```
├── Connection Screen (home)
│   ├── Adapter scan results
│   ├── Manual connection entry
│   └── Replay file picker
├── Dashboard (main screen after connection)
│   ├── Customizable widget grid
│   └── Edit mode toggle (drag/resize/add/remove)
├── Cell Detail Screen
│   ├── 16×6 cell grid with per-cell history sparkline
│   └── Module detail on tap
├── Session Log Screen
│   ├── Current session stats
│   ├── Export / share CSV
│   └── Past sessions list
└── Settings
    ├── Adapter preferences
    ├── Calibration offsets (CELL_VOLTAGE_OFFSET, CELL_VOLTAGE_FACTOR)
    ├── Threshold customization
    ├── Dashboard layout reset
    └── About / version
```

### 7.2 Dashboard widgets (v1 set)

All widgets subscribe reactively to `PackState` slices. Refresh rate: 2 Hz.

| Widget | Data source | Visual |
|--------|------------|--------|
| Cell heatmap | 96 cell voltages | 16×6 grid, color per threshold rules |
| Pack voltage gauge | packVoltage | Circular gauge, 0–420V range |
| Pack current gauge | packCurrent | Circular gauge, signed, ±1000A |
| SOC gauge | socPercent | Circular gauge, 0–100% |
| Temperature map | 16×2 module temps | Color-coded grid |
| Pack spread bar | cellVDelta | Horizontal bar with green/yellow/red zones |
| Contactor state | contactorState | Status badge with color |
| Isolation indicator | isolationKohm | Value + color badge |
| Connection status | transport metadata | Adapter name, frame rate, sweep % |
| Session controls | logger state | Start/stop, row count, duration, export |

### 7.3 Dashboard customization

- **Edit mode:** Long-press or tap edit icon to enter. Widgets get drag handles and resize corners.
- **Add widget:** Floating "+" button in edit mode shows available widget types.
- **Remove widget:** Drag to trash zone or swipe-dismiss in edit mode.
- **Layout persistence:** Serialized to `shared_preferences` as JSON. Survives app restart.
- **Reset:** Settings screen has "Reset dashboard layout" to restore defaults.

### 7.4 Cell detail screen

Tap any cell in the heatmap to navigate here. Shows:
- All 96 cells in a 16-row × 6-column grid
- Each cell shows voltage, color, and position label (M01B1 through M16B6, matching CSV column naming)
- Tap a module row to expand: shows both thermistor temps, module voltage, intra-module spread
- If session logging is active, shows a mini sparkline of each cell's voltage over the session

---

## 8. State management

Using **Riverpod** (successor to Provider, already in pubspec as `provider`). Key providers:

```
adapterProvider         → AdapterTransport (connection lifecycle)
canFrameStreamProvider  → Stream<CanFrame> (from protocol layer)
packStateProvider       → PackState (updated by decoder, consumed by UI)
sessionLoggerProvider   → SessionLogger (CSV writer)
dashboardLayoutProvider → DashboardLayout (widget positions/sizes)
settingsProvider        → AppSettings (thresholds, calibration, preferences)
```

All state flows uni-directionally: Transport → Protocol → Decoder → PackState → UI.

---

## 9. Project structure

```
testev/
├── android/
│   └── app/src/main/kotlin/.../
│       ├── BluetoothSppPlugin.kt        # BT SPP platform channel
│       └── MainActivity.kt
├── ios/
│   └── Runner/
│       ├── BluetoothSppPlugin.swift      # BT SPP platform channel
│       └── AppDelegate.swift
├── lib/
│   ├── main.dart
│   ├── transport/
│   │   ├── adapter_transport.dart        # abstract interface
│   │   ├── bluetooth_spp_transport.dart  # wraps native plugin
│   │   ├── wifi_tcp_transport.dart       # pure Dart, dart:io Socket
│   │   ├── replay_transport.dart         # log file playback
│   │   └── adapter_scanner.dart          # BT + WiFi discovery
│   ├── protocol/
│   │   ├── elm327_engine.dart            # AT init + frame parsing
│   │   ├── raw_can_parser.dart           # SLCAN + binary format
│   │   └── can_frame.dart                # shared CanFrame model
│   ├── decoder/
│   │   ├── decoder_engine.dart           # dispatch table + frame routing
│   │   ├── cell_frame_buffer.dart        # 0x6F2 mux accumulator
│   │   ├── pack_decoders.dart            # 0x102, 0x302, 0x312, 0x322
│   │   └── constants.dart                # all values from config.py
│   ├── data/
│   │   ├── pack_state.dart               # reactive state model
│   │   ├── threshold_evaluator.dart      # color-coding logic
│   │   ├── session_logger.dart           # CSV writer
│   │   └── providers.dart                # Riverpod providers
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── connection_screen.dart
│   │   │   ├── dashboard_screen.dart
│   │   │   ├── cell_detail_screen.dart
│   │   │   ├── session_log_screen.dart
│   │   │   └── settings_screen.dart
│   │   ├── widgets/
│   │   │   ├── cell_heatmap.dart
│   │   │   ├── pack_gauge.dart
│   │   │   ├── temp_map.dart
│   │   │   ├── spread_bar.dart
│   │   │   ├── contactor_badge.dart
│   │   │   ├── isolation_indicator.dart
│   │   │   ├── connection_status.dart
│   │   │   ├── session_controls.dart
│   │   │   └── dashboard_grid.dart       # drag/resize layout engine
│   │   └── theme/
│   │       └── testev_theme.dart
│   └── util/
│       └── log_parsers.dart              # ELM327 + python-can log readers
├── test/
│   ├── decoder/
│   │   ├── cell_frame_buffer_test.dart   # test against tesla_cells.csv data
│   │   └── pack_decoders_test.dart       # test against tesla_raw.csv data
│   ├── protocol/
│   │   └── elm327_engine_test.dart
│   └── fixtures/
│       ├── tesla_raw.csv                 # real CAN captures
│       ├── tesla_raw2.csv
│       └── tesla_cells.csv              # decoded reference data
├── assets/
│   └── (app icons, etc.)
├── pubspec.yaml
└── README.md
```

---

## 10. Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.5.0       # state management (replaces provider)
  shared_preferences: ^2.2.3     # dashboard layout persistence
  wakelock_plus: ^1.2.5          # keep screen on during monitoring
  path_provider: ^2.1.0          # app documents directory for logs
  share_plus: ^7.0.0             # share CSV exports
  csv: ^6.0.0                    # CSV writing
  permission_handler: ^11.3.0    # BT + location permissions
  cupertino_icons: ^1.0.8

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```

Removed from old pubspec: `flutter_bluetooth_serial` (replaced by native platform channels), `provider` (replaced by `flutter_riverpod`).

No `python-can` or `pyserial` dependencies — all CAN protocol handling is native Dart.

---

## 11. Testing strategy

**Unit tests (no hardware):**
- Decoder tests: Feed raw bytes from `tesla_raw.csv` into each decoder, verify output matches `tesla_cells.csv` reference data
- CellFrameBuffer: Verify 32-mux accumulation, partial snapshot on timeout, NaN filtering for garbage temps
- ELM327 engine: Feed recorded AT responses, verify frame parsing
- Threshold evaluator: Verify color assignments against known cell values
- CRC8: Port the test vectors from `tests.py` (e.g., `crc8([0x7f, 0x3c, 0xa5]) == 0x57`)

**Integration tests (with replay):**
- Full pipeline: ReplayTransport → Protocol → Decoder → PackState → verify all fields populated
- CSV logger: Verify output file matches expected header and value format
- Dashboard: Widget test with mock PackState, verify renders without error

**Manual testing (with hardware):**
- OBDLink MX+ over Bluetooth on Model S: verify frame rates, cell sweep timing
- MeatPi over WiFi on Model S: verify connection and raw frame parsing
- Cross-reference decoded values against ScanMyTesla or Tesla service screen

---

## 12. Build order

Implementation proceeds in this order, each step testable independently:

1. **Constants + CanFrame model** — Port `config.py` constants to Dart
2. **Decoders** — Port `decode.py` functions, test against CSV fixtures
3. **CellFrameBuffer** — Port mux accumulator, test against CSV fixtures
4. **PackState model** — Build reactive state, wire to decoders
5. **Threshold evaluator** — Port color-coding logic from config thresholds
6. **ELM327 protocol engine** — Port AT init + frame parsing from `adapter.py`
7. **Raw CAN parser** — SLCAN + binary format for MeatPi
8. **WiFi TCP transport** — Pure Dart socket connection
9. **Bluetooth SPP transport** — Native Kotlin + Swift platform channels
10. **Replay transport** — Port log parsers from `replay.py`
11. **Session logger** — Port CSV writer from `csv_logger.py`
12. **Connection screen UI**
13. **Dashboard grid engine** — Drag/resize/persist layout
14. **Dashboard widgets** — One at a time, starting with cell heatmap
15. **Cell detail screen**
16. **Settings screen**
17. **End-to-end testing with hardware**

---

## 13. Reference files

All Python source files that informed this design (to be committed to `docs/reference/python/` for cross-reference during porting):

| File | Purpose | Port target |
|------|---------|-------------|
| `config.py` | Constants, thresholds, CAN IDs | `lib/decoder/constants.dart` |
| `decode.py` | Frame decoders, CellFrameBuffer | `lib/decoder/` |
| `adapter.py` | ELM327Bus, adapter detection | `lib/protocol/elm327_engine.dart` |
| `replay.py` | Log parsers, BusReplayer | `lib/transport/replay_transport.dart` |
| `csv_logger.py` | Session CSV writer, header format | `lib/data/session_logger.dart` |
| `registers.py` | bq76PL536-A register map | Reference only (bench tool) |
| `transport.py` | 612500 baud UART framing | Reference only (bench tool) |
| `bms.py` | High-level BMS operations | Reference only (bench tool) |
| `crc.py` | CRC8 (poly 0x07) | Test vectors only |
| `cli.py` | CLI scanner | Reference only |
| `balance.py` | Cell balancer | Reference only (bench tool) |
| `brick_check.py` | Brick/drift detection | Future: battery health analysis |
| `tesla_cells.csv` | Decoded cell reference data | Test fixture |
| `tesla_raw.csv` | Raw CAN captures | Test fixture |
| `tesla_raw2.csv` | Raw CAN captures | Test fixture |

---

## 14. Future sub-projects

After this build is validated on the Model S:

1. **Vehicle data decoders** — Speed, tire PSI, power usage, odometer from non-BMS CAN IDs (0x358, 0x53A, 0x25C, etc.)
2. **Battery health analysis** — Drift detection over time (port `brick_check.py` logic), SOH estimation, weak cell identification
3. **Model 3/Y decoder profile** — JSON-driven CAN database, community DBC files
4. **Refreshed S/X decoder profile**
5. **USB serial transport** — For wired adapters
6. **Active diagnostics** — UDS write commands via 0x792/0x793 (DTC read, freeze frame)
7. **Data export** — Cloud sync, comparison across sessions, fleet tracking
