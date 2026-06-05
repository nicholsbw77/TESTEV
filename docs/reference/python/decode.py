"""
can_reader/decode.py — Tesla BMS CAN frame decoders.

Sources:
  - wk057 (Jason Hughes) CAN Deciphering v0.1
  - EVTV / Jack Rickard 0x6F2 Arduino source
  - TMC community corrections (two's complement temps, scaling)

All decoders are pure functions: (bytes) -> dict.
The CAN receive thread calls these; results feed into PackState.
"""

from __future__ import annotations

import math
import time
from typing import Optional

from config import (
    CELL_VOLTAGE_SCALE, CELL_VOLTAGE_OFFSET, CELL_VOLTAGE_FACTOR,
    CELL_TEMP_SCALE, PACK_VOLTAGE_SCALE, PACK_CURRENT_SCALE,
    PACK_CURRENT_OFFSET, MUX_CELL_MAX, MUX_TEMP_MIN, MUX_TEMP_MAX,
    BITS_PER_VALUE, VALUES_PER_FRAME, VALUE_MASK, NUM_CELLS,
)


# ── 0x6F2 — Cell voltages + temperatures ─────────────────────────────────────

class CellFrameBuffer:
    """
    Accumulates 0x6F2 mux frames and emits a complete snapshot when
    all 32 indices have been seen.

    The 0x6F2 message is a multiplexed sequence:
      - Byte 0: mux index (0x00–0x1F)
      - Bytes 1–7: 56 bits packed as four 14-bit values (little-endian bit order)

    Mux 0x00–0x17 (24 frames × 4 = 96): cell voltages, unsigned
    Mux 0x18–0x1F  (8 frames × 4 = 32): temperatures, signed two's complement
    """

    TOTAL_MUX = 32   # 0x00–0x1F

    def __init__(self):
        self._cells: list[Optional[float]] = [None] * 96
        self._temps: list[Optional[float]] = [None] * 32
        self._seen: set[int] = set()
        self._last_complete: float = 0.0

    def feed(self, data: bytes) -> Optional[dict]:
        """
        Feed one raw 8-byte 0x6F2 frame.
        Returns a dict with 'cells' and 'temps' when all 32 mux indices
        have been seen at least once, otherwise returns None.
        """
        if len(data) < 8:
            return None

        mux = data[0]
        if mux > 0x1F:
            return None

        # Extract 56-bit payload as a little-endian integer
        raw = int.from_bytes(data[1:8], byteorder="little")

        # Unpack four 14-bit values
        values = [(raw >> (i * BITS_PER_VALUE)) & VALUE_MASK
                  for i in range(VALUES_PER_FRAME)]

        if mux <= MUX_CELL_MAX:
            # Cell voltages — unsigned 14-bit
            base = mux * VALUES_PER_FRAME
            for i, v in enumerate(values):
                idx = base + i
                if idx < 96:
                    voltage = (v * CELL_VOLTAGE_SCALE + CELL_VOLTAGE_OFFSET) * CELL_VOLTAGE_FACTOR
                    self._cells[idx] = voltage
        else:
            # Temperatures — signed 14-bit (two's complement)
            base = (mux - MUX_TEMP_MIN) * VALUES_PER_FRAME
            for i, v in enumerate(values):
                idx = base + i
                if idx < 32:
                    # Sign-extend 14-bit value
                    if v & 0x2000:   # bit 13 set → negative
                        v = v - 0x4000
                    self._temps[idx] = v * CELL_TEMP_SCALE

        self._seen.add(mux)

        # Emit snapshot when all 32 mux indices seen
        if len(self._seen) == self.TOTAL_MUX:
            result = self._snapshot()
            # Reset for next sweep — keep values but clear seen set
            self._seen.clear()
            self._last_complete = time.monotonic()
            return result

        return None

    def _snapshot(self) -> dict:
        cells = [v if v is not None else float("nan") for v in self._cells]
        temps_flat = [v if v is not None else float("nan") for v in self._temps]
        # Reshape temps: 2 per module → list of (t1, t2) tuples
        module_temps = [
            (temps_flat[i * 2], temps_flat[i * 2 + 1])
            for i in range(16)
        ]
        return {
            "cells": cells,           # list[float], len=96
            "module_temps": module_temps,  # list[tuple], len=16
        }

    def partial_snapshot(self) -> dict:
        """Return whatever we have so far (for timeout recovery)."""
        return self._snapshot()

    @property
    def completion_pct(self) -> float:
        return len(self._seen) / self.TOTAL_MUX * 100


# ── 0x102 — Pack voltage, current, terminal temperature ──────────────────────

def decode_0x102(data: bytes) -> dict:
    """
    ID 0x102: BMS Current and Voltage
    Length: 6 or 8 bytes, ~100 Hz

    Bytes 0/1: pack voltage (unsigned, scale 0.01 V)
    Bytes 2/3: pack current (signed 15-bit, scale 0.1 A, offset -1000 A)
    Bytes 6/7 (8-byte frame only): negative terminal temp

    Source: wk057 v0.1 — verified by community
    """
    if len(data) < 6:
        return {}

    pack_v = ((data[0] << 8) | data[1]) * PACK_VOLTAGE_SCALE

    raw_i = ((data[2] & 0x7F) << 8) | data[3]   # 15-bit signed
    if data[2] & 0x80:
        raw_i -= 0x8000
    pack_i = raw_i * PACK_CURRENT_SCALE + PACK_CURRENT_OFFSET

    result = {"pack_voltage": pack_v, "pack_current": pack_i}

    if len(data) >= 8:
        raw_temp = (data[6] | ((data[7] & 0x07) << 8))
        temp_c = raw_temp * 0.1 - 40.0   # 0.1°C/LSB, -40°C offset
        result["neg_terminal_temp_c"] = temp_c

    return result


# ── 0x302 — State of Charge, energy counters ─────────────────────────────────

def decode_0x302(data: bytes) -> dict:
    """
    ID 0x302: BMS SoC and energy counters
    Note: exact byte layout varies between firmware revisions.
    Values below are community-derived best-effort; verify on bench.
    """
    if len(data) < 8:
        return {}

    # SoC: bytes 0/1, 10-bit, scale 0.1%
    soc_raw = ((data[0] & 0x03) << 8) | data[1]
    soc = soc_raw * 0.1

    # Energy counters: bytes 2–5 (kWh discharged) and 4–7 (kWh charged)
    # These are community approximations — log raw and verify
    kwh_out = ((data[2] << 8) | data[3]) * 0.01
    kwh_in  = ((data[4] << 8) | data[5]) * 0.01

    return {
        "soc_percent": soc,
        "kwh_discharged": kwh_out,
        "kwh_charged": kwh_in,
        "raw": data.hex(" "),
    }


# ── 0x312 — Contactor state ───────────────────────────────────────────────────

_CONTACTOR_STATES = {
    0x00: "OPEN",
    0x01: "PRECHARGE",
    0x03: "CLOSED",
    0x04: "FAULT",
}

def decode_0x312(data: bytes) -> dict:
    """
    ID 0x312: Contactor state.
    Byte 0 low nibble encodes state. Community-derived; confirm on bench.
    On the bench (no HV load, no precharge commanded): expect OPEN.
    """
    if len(data) < 1:
        return {}
    state_code = data[0] & 0x0F
    state = _CONTACTOR_STATES.get(state_code, f"UNKNOWN(0x{state_code:02X})")
    return {"contactor_state": state, "raw_byte0": data[0]}


# ── 0x322 — Isolation resistance ─────────────────────────────────────────────

def decode_0x322(data: bytes) -> dict:
    """
    ID 0x322: Isolation resistance.
    Bytes 0/1: isolation in kΩ (unsigned). Scale factor TBC on bench.
    Good isolation: >500 kΩ. Fault threshold: <100 kΩ.
    """
    if len(data) < 2:
        return {}
    isolation_kohm = ((data[0] << 8) | data[1]) * 1.0   # scale TBC
    return {"isolation_kohm": isolation_kohm}


# ── Dispatch table ─────────────────────────────────────────────────────────────

_DECODERS = {
    0x102: decode_0x102,
    0x302: decode_0x302,
    0x312: decode_0x312,
    0x322: decode_0x322,
}

def decode_frame(can_id: int, data: bytes) -> dict:
    """
    Dispatch a CAN frame to the appropriate decoder.
    Returns decoded dict, or {"raw": hex_string} for unknown IDs.
    """
    decoder = _DECODERS.get(can_id)
    if decoder:
        try:
            return decoder(data)
        except Exception as e:
            return {"error": str(e), "raw": data.hex(" ")}
    return {"raw": data.hex(" ")}
