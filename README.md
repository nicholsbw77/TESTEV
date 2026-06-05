# TESTEV v2 — Tesla EV Battery Diagnostic Tool

Cross-platform (Android + iOS) real-time battery diagnostic app for Tesla vehicles.

## What it does

- Connects to Tesla Model S via **OBDLink MX/LX** (Bluetooth) or **MeatPi/WiCAN** (WiFi)
- Decodes BMS CAN frames: 96 cell voltages, 32 temperatures, pack voltage/current/SOC, contactor state, isolation resistance
- Customizable live dashboard with color-coded cell heatmap, gauges, and alerts
- Session logging to CSV (cross-compatible with the Python bench tool)
- Replay mode for development and testing without hardware

## Architecture

```
UI Layer         → Flutter widgets, customizable dashboard
Data Layer       → PackState reactive model, threshold evaluation, CSV logger
Decoder Layer    → CAN frame decoders (0x6F2, 0x102, 0x302, 0x312, 0x322)
Protocol Layer   → ELM327 AT engine, SLCAN/raw CAN parser
Transport Layer  → Bluetooth SPP (native), WiFi TCP (Dart), Replay
```

## Branches

- **`main`** — Original v1 prototype
- **`v2`** — Clean-architecture rebuild (this branch)

## Project structure

See `docs/specs/2025-06-05-testev-v2-design.md` for the full design spec.

## Related repos

- [TESLA-BMB](https://github.com/nicholsbw77/TESLA-BMB) — Python Qt6 GUI for Gen1 BMB bench diagnostics (612500 baud UART)
- [tesla-bms-bench](https://github.com/nicholsbw77/tesla-bms-bench) — Python bench testing tools

## Getting started

```bash
flutter pub get
flutter run
```

## Hardware tested

- OBDLink MX+ (Bluetooth SPP) — STN2120, handles ~1000 frames/sec
- MeatPi WiCAN (WiFi TCP) — SLCAN protocol, raw CAN bus access
