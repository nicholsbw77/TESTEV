"""
config.py — Shared constants for the Tesla BMS Bench Tester.

All thresholds, CAN IDs, scaling factors, and pack geometry live here.
Edit this file when calibrating voltage scaling against DMM readings.
"""

# ── Pack geometry ─────────────────────────────────────────────────────────────
NUM_MODULES      = 16
CELLS_PER_MODULE = 6
NUM_CELLS        = NUM_MODULES * CELLS_PER_MODULE  # 96

# ── CAN bus ───────────────────────────────────────────────────────────────────
CAN_BITRATE      = 500_000   # PT_CAN is 500 kbit/s

# All BMS-originated IDs end in 0x_2 (observed by EVTV / wk057)
CAN_ID_BMS_VOLT_CURR    = 0x102   # pack voltage, current, terminal temp
CAN_ID_BMS_SOC          = 0x302   # SoC %, energy counters
CAN_ID_BMS_CONTACTOR    = 0x312   # contactor state
CAN_ID_BMS_ISOLATION    = 0x322   # isolation resistance
CAN_ID_BMS_CELL_BLOCK   = 0x6F2   # muxed: 96 cell voltages + 32 temps

# Full set of known BMS broadcast IDs (stub-decode everything)
CAN_BMS_ALL_IDS = {
    0x102, 0x202, 0x212, 0x222, 0x232, 0x242,
    0x302, 0x312, 0x322, 0x332, 0x342, 0x352,
    0x362, 0x372, 0x382, 0x3A2, 0x3B2, 0x3C2,
    0x3D2, 0x3E2, 0x3F2, 0x402, 0x412, 0x502,
    0x512, 0x532, 0x542, 0x552, 0x562, 0x5D2,
    0x6F2, 0x7E2,
}

# UDS addressing (to be confirmed on bench)
UDS_REQUEST_ID   = 0x792
UDS_RESPONSE_ID  = 0x793

# ── 0x6F2 decode constants ────────────────────────────────────────────────────
# 32 frames total: mux 0x00–0x1F
# Mux 0x00–0x17 (24 frames × 4 values = 96): cell voltages
# Mux 0x18–0x1F  (8 frames × 4 values = 32): module temperatures (2 per module)
MUX_CELL_MAX     = 0x17
MUX_TEMP_MIN     = 0x18
MUX_TEMP_MAX     = 0x1F
VALUES_PER_FRAME = 4
BITS_PER_VALUE   = 14
VALUE_MASK       = 0x3FFF

# Voltage: 14-bit unsigned, scale = 0.000305 V/LSB (0–5V range in 14 bits)
# Source: wk057 CAN Deciphering v0.1, verified by EVTV bench work
CELL_VOLTAGE_SCALE   = 0.000305   # V per LSB

# Temperature: 14-bit signed (two's complement), scale = 0.0122 °C/LSB
# Source: wk057; verified matches Tesla diagnostic screen display
CELL_TEMP_SCALE      = 0.0122     # °C per LSB

# Calibration overrides — adjust if CAN voltages drift vs DMM/serial readings.
# cell_voltage = (raw * CELL_VOLTAGE_SCALE + CELL_VOLTAGE_OFFSET) * CELL_VOLTAGE_FACTOR
# Leave OFFSET=0 and FACTOR=1.0 until you have bench calibration data.
CELL_VOLTAGE_OFFSET  = 0.0
CELL_VOLTAGE_FACTOR  = 1.0

# ── 0x102 decode constants ────────────────────────────────────────────────────
PACK_VOLTAGE_SCALE   = 0.01       # bytes 0/1 → V
PACK_CURRENT_SCALE   = 0.1        # bytes 2/3 → A (signed)
PACK_CURRENT_OFFSET  = -1000.0    # subtract after scaling (verify empirically)

# ── Serial / BMB ─────────────────────────────────────────────────────────────
SERIAL_BAUD_DIRECT  = 612_500   # direct FTDI connection to BMB daisy-chain
SERIAL_BAUD_BRIDGE  = 921_600   # via ESP32 bridge firmware

# ── Voltage thresholds (for GUI color coding) ─────────────────────────────────
CELL_V_NOMINAL_MIN  = 3.0    # V — below this is a real problem
CELL_V_NOMINAL_MAX  = 4.20   # V — above this needs investigation
CELL_V_BALANCE_HIGH = 4.15   # V — above this cells should be bled before reinstall

CELL_DELTA_GREEN_MV =  20    # mV — pack spread is healthy
CELL_DELTA_YELLOW_MV = 50    # mV — worth watching
CELL_DELTA_RED_MV   = 100    # mV — investigate before reinstall

# Relative-to-mean thresholds (from existing bmb_gui.py)
WARN_MV   =  6   # mV below mean → yellow
CRIT_MV   = 12   # mV below mean → red
HIGH_MV   =  6   # mV above mean → blue
SPREAD_WARN_MV = 15   # intra-module spread warning

# Temperature thresholds
TEMP_WARN_C  = 40.0   # °C — flag as warm
TEMP_CRIT_C  = 50.0   # °C — flag as hot

# Isolation
ISOLATION_WARN_KOHM  = 500   # kΩ — below this flag
ISOLATION_CRIT_KOHM  = 100   # kΩ — critical

# ── GUI refresh ───────────────────────────────────────────────────────────────
GUI_REFRESH_HZ       = 2     # target UI update rate
CAN_SWEEP_TIMEOUT_S  = 1.0   # max seconds to wait for a full 0x6F2 sweep

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_DIR              = "logs"
SESSION_LOG_SUFFIX   = "_session.csv"
INFO_LOG_SUFFIX      = "_session_info.txt"
