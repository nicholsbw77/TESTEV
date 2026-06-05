# TESTEV v2 — Implementation Plan

**Spec:** `2025-06-05-testev-v2-design.md`
**Approach:** Bottom-up — each phase is testable before the next begins.

---

## Phase 1: Project scaffold + constants
**Goal:** Fresh Flutter project with all config values ported from Python.

### Tasks
1. Create new Flutter project `testev` with Android + iOS targets
2. Set up `pubspec.yaml` with dependencies from spec §10 (flutter_riverpod, shared_preferences, wakelock_plus, path_provider, share_plus, csv, permission_handler)
3. Create directory structure per spec §9 (transport/, protocol/, decoder/, data/, ui/)
4. Port `config.py` → `lib/decoder/constants.dart`:
   - All CAN IDs (0x6F2, 0x102, 0x302, 0x312, 0x322, full BMS ID set)
   - 0x6F2 decode constants (MUX ranges, BITS_PER_VALUE=14, VALUE_MASK=0x3FFF, scales)
   - 0x102/0x302 scales and offsets
   - Voltage/temp/isolation thresholds (all WARN/CRIT values)
   - GUI_REFRESH_HZ, CAN_SWEEP_TIMEOUT_S
5. Create `lib/protocol/can_frame.dart` — CanFrame model class
6. Copy Python reference files + CSV test fixtures into `test/fixtures/`

### Verification
- `flutter analyze` passes with zero errors
- Constants file compiles, values match config.py exactly
- CanFrame model instantiates correctly

---

## Phase 2: Decoders (core logic, no I/O)
**Goal:** All five CAN frame decoders ported and tested against real data.

### Tasks
1. Port `decode_0x102` → `lib/decoder/pack_decoders.dart`
   - Pack voltage: big-endian unsigned × 0.01
   - Pack current: signed 15-bit × 0.1 + offset(-1000)
   - Neg terminal temp: 11-bit × 0.1 - 40.0
2. Port `decode_0x302` → same file
   - SOC: 10-bit × 0.1%
   - kWh counters: × 0.01
3. Port `decode_0x312` → same file (contactor state lookup)
4. Port `decode_0x322` → same file (isolation kΩ)
5. Port `CellFrameBuffer` → `lib/decoder/cell_frame_buffer.dart`
   - 32-mux accumulator with seen-set tracking
   - 14-bit unsigned cell voltage extraction (little-endian 56-bit payload)
   - 14-bit signed two's complement temperature extraction
   - Complete sweep emission + partial snapshot on timeout
   - Temperature filtering: reject values outside -40°C to +120°C
6. Create `lib/decoder/decoder_engine.dart` — dispatch table routing CAN IDs to decoders
7. Write unit tests:
   - `test/decoder/pack_decoders_test.dart` — feed raw bytes from tesla_raw.csv, verify decoded values
   - `test/decoder/cell_frame_buffer_test.dart` — feed complete 0x6F2 sequence, verify against tesla_cells.csv reference
   - Test edge cases: short frames, unknown mux indices, NaN temps

### Verification
- All decoder tests pass
- Decoded cell voltages from test fixtures match tesla_cells.csv within 0.001V
- CellFrameBuffer completion % tracks correctly (0→100% over 32 frames)

---

## Phase 3: Data layer
**Goal:** Reactive PackState model wired to decoders with threshold evaluation.

### Tasks
1. Create `lib/data/pack_state.dart` — full model per spec §6.1
   - 96 cell voltages, 16×2 module temps, pack-level fields
   - Derived properties: cellVMin, cellVMax, cellVDelta, cellVMean
   - Module voltages: computed as sum of each module's 6 cells
2. Create `lib/data/threshold_evaluator.dart`
   - Cell color assignment (green/yellow/red/blue relative to mean)
   - Pack spread color (green/yellow/red bands)
   - Absolute voltage warnings
   - Temperature and isolation warnings
   - Intra-module spread warnings (>15mV)
3. Create `lib/data/providers.dart` — Riverpod providers per spec §8
4. Wire decoder output → PackState updates via StreamProvider
5. Write tests:
   - ThresholdEvaluator with known cell arrays, verify color assignments
   - PackState derived properties with edge cases (all NaN, single cell, full pack)

### Verification
- PackState correctly populated from decoder output
- Threshold colors match Python tool behavior for same input data
- Module voltage sums match expected pack voltage within tolerance

---

## Phase 4: Protocol layer
**Goal:** ELM327 AT engine and raw CAN parser emitting CanFrame streams.

### Tasks
1. Create `lib/protocol/elm327_engine.dart`
   - AT initialization sequence (ATZ, ATE0, ATL0, ATH1, ATCAF0, ATCSM1, ATMA)
   - Line-by-line frame parsing with regex from adapter.py
   - Frame rate counter (rolling 1-second window)
   - Error recovery: re-send ATMA on 2s stall, full re-init on failure
   - Configurable init timeout for slow adapters
2. Create `lib/protocol/raw_can_parser.dart`
   - SLCAN format detection and parsing
   - Binary format detection and parsing (MeatPi native)
   - Auto-detect on first received bytes
3. Write tests:
   - Feed recorded ELM327 output strings, verify CanFrame output
   - Feed SLCAN strings, verify parsing
   - Test error recovery paths (malformed lines, stalls)

### Verification
- ELM327 engine parses every line from tesla_raw.csv correctly
- Frame rate counter produces sane values
- Both parsers emit identical CanFrame for same logical frame

---

## Phase 5: Transport layer
**Goal:** WiFi, Bluetooth, and Replay transports implementing AdapterTransport.

### Tasks
1. Create `lib/transport/adapter_transport.dart` — abstract interface
2. Create `lib/transport/wifi_tcp_transport.dart`
   - Pure Dart `dart:io Socket` connection
   - Configurable IP/port (default 192.168.4.1:3333)
   - Auto-reconnect on disconnect with backoff
   - Pipes raw bytes to protocol layer
3. Create `lib/transport/replay_transport.dart`
   - Port log parsers from replay.py (ELM327 format, python-can format, raw CSV format)
   - Timing-aware playback with speed multiplier
   - Loop mode
4. Create `lib/transport/bluetooth_spp_transport.dart` — Dart side wrapping platform channel
5. Create `android/app/src/main/kotlin/.../BluetoothSppPlugin.kt`
   - BT device discovery (filter by name patterns)
   - SPP UUID connection
   - Bidirectional byte stream via EventChannel
6. Create `ios/Runner/BluetoothSppPlugin.swift`
   - ExternalAccessory for MFi OBDLink
   - CoreBluetooth for generic BLE ELM327
   - Same channel interface as Android
7. Create `lib/transport/adapter_scanner.dart`
   - Bluetooth scan with name pattern matching
   - WiFi SSID detection
   - Unified adapter list for connection screen

### Verification
- ReplayTransport plays back tesla_raw.csv at correct timing
- WiFi transport connects/disconnects cleanly (test with netcat or MeatPi)
- Bluetooth transport discovers and connects to OBDLink (manual test on device)
- Full pipeline: ReplayTransport → ELM327Engine → Decoder → PackState populates all fields

---

## Phase 6: Session logger
**Goal:** CSV logging with cross-compatible format.

### Tasks
1. Create `lib/data/session_logger.dart`
   - Port header and row format from csv_logger.py exactly
   - 2 Hz logging rate
   - Session info summary on stop
   - File stored in app documents directory
2. Add export functionality — share CSV via share_plus
3. Write tests:
   - Log a PackState, verify CSV header and row format
   - Verify cross-compatibility: output parseable by Python tool

### Verification
- CSV header matches csv_logger.py `_HEADER` exactly
- Python `csv.DictReader` can parse the output file
- Session info file written with correct duration and stats

---

## Phase 7: Connection screen UI
**Goal:** First screen users see — scan for adapters, connect, or load replay file.

### Tasks
1. Create `lib/ui/screens/connection_screen.dart`
   - Bluetooth adapter scan results with name + signal strength
   - WiFi adapter detection
   - Manual connection entry (IP/port for WiFi, device name for BT)
   - "Load replay file" button → file picker
   - Connection progress indicator
   - Error display with retry option
2. Handle platform permissions (Bluetooth, location for BT scan on Android)
3. Create `lib/ui/theme/testev_theme.dart` — dark theme suitable for in-car use

### Verification
- App launches to connection screen
- BT scan shows nearby devices (filtered by name pattern)
- Replay file loads and transitions to dashboard
- Permission dialogs appear correctly on Android + iOS

---

## Phase 8: Dashboard UI
**Goal:** Customizable widget grid with all v1 widgets.

### Tasks
1. Create `lib/ui/widgets/dashboard_grid.dart`
   - Grid layout engine with drag-to-reorder
   - Resize handles on widgets in edit mode
   - Add/remove widgets
   - Layout serialization to shared_preferences
2. Create each widget (one at a time, each independently testable):
   a. `cell_heatmap.dart` — 16×6 color-coded grid
   b. `pack_gauge.dart` — Circular gauge (voltage, current, SOC variants)
   c. `temp_map.dart` — 16×2 temperature grid
   d. `spread_bar.dart` — Horizontal bar with threshold zones
   e. `contactor_badge.dart` — Status indicator
   f. `isolation_indicator.dart` — Value + color
   g. `connection_status.dart` — Adapter info, frame rate, sweep %
   h. `session_controls.dart` — Start/stop/export
3. Create `lib/ui/screens/dashboard_screen.dart` — hosts the grid
4. Wire all widgets to PackState providers

### Verification
- Dashboard renders with default layout
- Each widget updates at 2 Hz from replay data
- Edit mode: drag, resize, add, remove all work
- Layout persists across app restart
- Cell heatmap colors match Python tool for same data

---

## Phase 9: Detail screens + settings
**Goal:** Cell detail drilldown and app settings.

### Tasks
1. Create `lib/ui/screens/cell_detail_screen.dart`
   - 16×6 grid with M01B1–M16B6 labels
   - Tap module row to expand (temps, module V, spread)
   - Mini sparkline if session logging active
2. Create `lib/ui/screens/session_log_screen.dart`
   - Current session stats
   - Past sessions list from app storage
   - Share/export individual sessions
3. Create `lib/ui/screens/settings_screen.dart`
   - Adapter preferences (default IP, BT device name)
   - Calibration offsets (CELL_VOLTAGE_OFFSET, CELL_VOLTAGE_FACTOR)
   - Threshold customization
   - Dashboard layout reset
   - About/version

### Verification
- Cell detail shows correct per-cell voltage with color
- Module expansion shows both temps and intra-module spread
- Settings changes persist and take effect immediately
- Calibration offset changes reflect in decoded values

---

## Phase 10: Hardware integration testing
**Goal:** Validate everything works on a real Model S.

### Tasks
1. Build APK, install on Android device
2. Test OBDLink MX+ over Bluetooth:
   - Scan, pair, connect
   - Verify AT init sequence completes
   - Verify frame rate (~1000 frames/sec expected from STN2120)
   - Verify cell voltages match ScanMyTesla or Tesla service screen
   - Run for 30+ minutes, verify no disconnects or memory leaks
3. Test MeatPi over WiFi:
   - Connect to MeatPi AP
   - Verify TCP connection and raw frame parsing
   - Cross-reference with OBDLink values
4. Test on iOS (if available):
   - OBDLink via ExternalAccessory
   - Verify same data quality as Android
5. Calibration pass:
   - Compare decoded pack voltage against known reference
   - Adjust CELL_VOLTAGE_OFFSET/FACTOR if needed
   - Verify temperature readings are sensible (room temp ~20-25°C)
6. Session logging test:
   - Record 10-minute session
   - Export CSV, open in Python tool, verify compatibility
7. Stress test:
   - Dashboard with all widgets visible
   - Verify 2 Hz refresh maintains smooth scrolling
   - Monitor battery and CPU usage on phone

### Verification
- All decoded values match ScanMyTesla within acceptable tolerance
- No crashes or ANRs over 30-minute session
- CSV export loads in Python tool without errors
- App functions identically in replay mode and live mode

---

## Estimated effort per phase

| Phase | Description | Estimated sessions |
|-------|-------------|--------------------|
| 1 | Scaffold + constants | 1 |
| 2 | Decoders | 2 |
| 3 | Data layer | 1 |
| 4 | Protocol layer | 1–2 |
| 5 | Transport layer | 2–3 |
| 6 | Session logger | 1 |
| 7 | Connection screen | 1–2 |
| 8 | Dashboard UI | 3–4 |
| 9 | Detail screens + settings | 2 |
| 10 | Hardware testing | 1–2 |
| **Total** | | **~15–20 sessions** |

Phases 1–3 can be completed and fully tested without any hardware. Phase 5 (Bluetooth native code) is the highest-risk phase due to platform-specific quirks.
