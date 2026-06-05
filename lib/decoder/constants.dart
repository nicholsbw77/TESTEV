/// Tesla BMS CAN decoder constants.
///
/// Ported from Python `config.py` — all thresholds, CAN IDs, scaling factors,
/// and pack geometry. Edit calibration values when comparing against DMM readings.
///
/// Sources:
///   - wk057 (Jason Hughes) CAN Deciphering v0.1
///   - EVTV / Jack Rickard 0x6F2 Arduino source
///   - TMC community corrections (two's complement temps, scaling)
library;

// ── Pack geometry ────────────────────────────────────────────────────────────

const int numModules = 16;
const int cellsPerModule = 6;
const int numCells = numModules * cellsPerModule; // 96

// ── CAN bus ──────────────────────────────────────────────────────────────────

const int canBitrate = 500000; // PT_CAN is 500 kbit/s

/// Primary BMS CAN IDs (decoded in v1)
const int canIdBmsVoltCurr = 0x102; // pack voltage, current, terminal temp
const int canIdBmsSoc = 0x302; // SoC %, energy counters
const int canIdBmsContactor = 0x312; // contactor state
const int canIdBmsIsolation = 0x322; // isolation resistance
const int canIdBmsCellBlock = 0x6F2; // muxed: 96 cell voltages + 32 temps

/// Vehicle-bus CAN IDs (from OBDLink via vehicle OBD port)
const int canIdVehVoltCurr = 0x132; // pack voltage/current on vehicle bus
const int canIdVehLimits = 0x202; // charge/discharge current limits
const int canIdVehPowerLimits = 0x232; // regen/discharge kW limits
const int canIdVehSoc = 0x332; // SoC on vehicle bus (multiplexed)
const int canIdVehPowerMux = 0x392; // power limits, muxed by byte 0
const int canIdBmsSerial1 = 0x542; // serial number part 1
const int canIdBmsSerial2 = 0x552; // serial number part 2
const int canIdBmsWot = 0x7E2; // WOT current limit

/// Full set of known BMS broadcast IDs (stub-decode everything)
const Set<int> canBmsAllIds = {
  0x102, 0x132, 0x202, 0x212, 0x222, 0x232, 0x242,
  0x302, 0x312, 0x322, 0x332, 0x342, 0x352,
  0x362, 0x372, 0x382, 0x392, 0x3A2, 0x3B2, 0x3C2,
  0x3D2, 0x3E2, 0x3F2, 0x402, 0x412, 0x502,
  0x512, 0x532, 0x542, 0x552, 0x562, 0x5D2,
  0x6F2, 0x7E2,
};

/// UDS addressing (future active diagnostics)
const int udsRequestId = 0x792;
const int udsResponseId = 0x793;

// ── 0x6F2 decode constants ───────────────────────────────────────────────────

/// 32 frames total: mux 0x00–0x1F
/// Mux 0x00–0x17 (24 frames × 4 values = 96): cell voltages
/// Mux 0x18–0x1F  (8 frames × 4 values = 32): module temperatures
const int muxCellMax = 0x17;
const int muxTempMin = 0x18;
const int muxTempMax = 0x1F;
const int totalMuxFrames = 32; // 0x00–0x1F
const int valuesPerFrame = 4;
const int bitsPerValue = 14;
const int valueMask = 0x3FFF;

/// Voltage: 14-bit unsigned, scale = 0.000305 V/LSB (5.0V full-scale in 14 bits)
/// CAN 0x6F2 uses 5.0V full-scale vs bq76PL536 register 6.25V full-scale.
/// Source: wk057 CAN Deciphering v0.1, verified by EVTV bench work
const double cellVoltageScale = 0.000305; // V per LSB

/// Temperature: 14-bit signed (two's complement), scale = 0.0122 °C/LSB
/// Source: wk057; verified matches Tesla diagnostic screen display
const double cellTempScale = 0.0122; // °C per LSB

/// Calibration overrides — adjust if CAN voltages drift vs DMM/serial readings.
/// cell_voltage = (raw * cellVoltageScale + cellVoltageOffset) * cellVoltageFactor
double cellVoltageOffset = 0.0;
double cellVoltageFactor = 1.0;

/// Temperature sanity bounds — values outside this range are treated as invalid
const double tempMinValid = -40.0; // °C
const double tempMaxValid = 120.0; // °C

// ── 0x102 decode constants ───────────────────────────────────────────────────

const double packVoltageScale = 0.01; // bytes 0/1 → V
const double packCurrentScale = 0.1; // bytes 2/3 → A (signed)
const double packCurrentOffset = -1000.0; // subtract after scaling

// ── 0x302 decode constants ───────────────────────────────────────────────────

const double socScale = 0.01; // bytes 0/1 → %
const double kwhScale = 0.01; // energy counters → kWh

// ── Voltage thresholds (for UI color coding) ─────────────────────────────────

const double cellVNominalMin = 3.0; // V — below this is a real problem
const double cellVNominalMax = 4.20; // V — above this needs investigation
const double cellVBalanceHigh = 4.15; // V — bleed before reinstall

const double cellDeltaGreenMv = 20; // mV — pack spread is healthy
const double cellDeltaYellowMv = 50; // mV — worth watching
const double cellDeltaRedMv = 100; // mV — investigate before reinstall

/// Relative-to-mean thresholds (from bmb_gui.py)
const double warnMv = 6; // mV below mean → yellow
const double critMv = 12; // mV below mean → red
const double highMv = 6; // mV above mean → blue
const double spreadWarnMv = 15; // intra-module spread warning

// ── Temperature thresholds ───────────────────────────────────────────────────

const double tempWarnC = 40.0; // °C — flag as warm
const double tempCritC = 50.0; // °C — flag as hot

// ── Isolation thresholds ─────────────────────────────────────────────────────

const double isolationWarnKohm = 500; // kΩ — below this flag
const double isolationCritKohm = 100; // kΩ — critical

// ── Contactor states ─────────────────────────────────────────────────────────

const Map<int, String> contactorStates = {
  0x00: 'OPEN',
  0x01: 'PRECHARGE',
  0x03: 'CLOSED',
  0x04: 'FAULT',
};

// ── GUI / app behavior ───────────────────────────────────────────────────────

const int guiRefreshHz = 2; // target UI update rate
const double canSweepTimeoutS = 1.0; // max seconds for full 0x6F2 sweep

// ── Serial / BMB (bench tool reference only) ─────────────────────────────────

const int serialBaudDirect = 612500; // direct FTDI to BMB daisy-chain
const int serialBaudBridge = 921600; // via ESP32 bridge firmware

// ── bq76PL536-A register constants (bench reference) ─────────────────────────

/// Cell voltage scale for direct register reads (6.25V full-scale / 16383)
/// Different from CAN 0x6F2 scale which uses 5.0V full-scale.
const double cellVScaleRegister = 0.000382002; // V per ADC count
const double moduleVScale = 0.002048169; // V per ADC count for pack voltage

/// Thermistor conversion (Beta equation for Tesla 10K NTC)
const double tempRRef = 33046.0; // reference resistor (Ω)
const double tempR0 = 10000.0; // NTC nominal at 25°C (Ω)
const double tempT0 = 298.15; // 25°C in Kelvin
const double tempBeta = 4365.0; // Beta coefficient

// ── CRC8 (bench tool UART protocol) ─────────────────────────────────────────

/// Polynomial: 0x07 (x^8 + x^2 + x + 1), non-reflected, init=0
/// Used by bq76PL536-A UART wrapper on the Tesla BMS slave board.
const int crc8Poly = 0x07;
