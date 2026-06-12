"""Decoder unit tests — runnable with plain `python3 tests/test_decoders.py`
(no pytest, no Qt required: decoders only touch VehicleState).

Vectors mirror the Flutter app's verified decode (pack_state.dart) and the
simulator encoders, so encode→decode must round-trip.
"""

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tesladash.decoders import TeslaDecoder, bits_le              # noqa: E402
from tesladash.frames import CanFrame                             # noqa: E402
from tesladash.sources import SimulatorSource                     # noqa: E402
from tesladash.state import VehicleState                          # noqa: E402


def approx(a, b, tol=1e-6):
    assert abs(a - b) <= tol, f"{a} != {b} (tol {tol})"


def fresh(vehicle_bus=True):
    st = VehicleState()
    return st, TeslaDecoder(st, vehicle_bus=vehicle_bus)


def test_132_pack_voltage_current():
    st, dec = fresh()
    # 350.00 V → raw 35000 = 0x88B8 BE; -123.4 A → raw -1234 = 0xFB2E BE
    dec.feed(CanFrame(0x132, bytes([0x88, 0xB8, 0xFB, 0x2E, 0, 0, 0, 0])))
    approx(st.num("pack_voltage"), 350.00, 1e-9)
    approx(st.num("pack_current"), -123.4, 1e-9)
    # invalid current sentinel
    dec.feed(CanFrame(0x132, bytes([0x88, 0xB8, 0x7F, 0xFF, 0, 0, 0, 0])))
    assert math.isnan(st.num("pack_current"))


def test_102_gated_by_bus_profile():
    st, dec = fresh(vehicle_bus=True)
    dec.feed(CanFrame(0x102, bytes([0x88, 0xB8, 0, 0, 0, 0, 0, 0])))
    assert math.isnan(st.num("pack_voltage")), "0x102 must be ignored on vehicle bus"
    st, dec = fresh(vehicle_bus=False)
    dec.feed(CanFrame(0x102, bytes([0x88, 0xB8, 0, 0, 0, 0, 0, 0])))
    approx(st.num("pack_voltage"), 350.0, 1e-9)


def test_392_power_limit_muxes():
    st, dec = fresh()
    # mux 01: discharge 310.00 kW → raw 31000 BE in [1:2]; regen 60.00 kW in [4:5]
    dec.feed(CanFrame(0x392, bytes([0x01, 0x79, 0x18, 0x00, 0x17, 0x70, 0x00, 0x00])))
    approx(st.num("max_discharge_kw"), 310.0, 1e-9)
    approx(st.num("max_regen_kw"), 60.0, 1e-9)
    # mux 04: 4353.1 A → raw 43531 = 0xAA0B LE in [4:5]
    dec.feed(CanFrame(0x392, bytes([0x04, 0, 0, 0, 0x0B, 0xAA, 0, 0])))
    approx(st.num("max_discharge_current"), 4353.1, 1e-6)
    approx(st.num("wot_current_limit"), 4353.1, 1e-6)


def test_332_soc_cross_check():
    st, dec = fresh()
    # without cell data, 0x332 must be rejected
    dec.feed(CanFrame(0x332, bytes([0x1E, 0x14, 0, 0, 0, 0, 0, 0])))
    assert math.isnan(st.num("soc"))
    # cell avg 3.95 V → est SoC ≈ 79% ; 77.00% within 30 → accepted
    st.cells[:] = [3.95] * 96
    dec.feed(CanFrame(0x332, bytes([0x1E, 0x14, 0, 0, 0, 0, 0, 0])))  # 7700 BE
    approx(st.num("soc"), 77.0, 1e-9)


def test_6f2_full_sweep():
    st, dec = fresh()
    cells = [3.8 + 0.001 * i for i in range(96)]
    for mux in range(32):
        data = SimulatorSource._enc_6f2(mux, cells, batt_temp=25.0, t=0.0)
        dec.feed(CanFrame(0x6F2, data))
    valid = [c for c in st.cells if not math.isnan(c)]
    assert len(valid) == 96, f"expected 96 cells, got {len(valid)}"
    # 0.000305 V/count quantization + the simulator's ±3 mV per-cell wobble
    approx(st.cells[0], 3.8, 0.004)
    approx(st.cells[95], 3.895, 0.004)
    temps = [t for t in st.module_temps if not math.isnan(t)]
    assert len(temps) == 32
    assert all(20.0 < t < 30.0 for t in temps), temps


def test_6f2_negative_temp():
    st, dec = fresh()
    # -10 °C → raw = -10/0.0122 = -819.67 → -820 → 14-bit two's complement
    raw = (-820) & 0x3FFF
    payload = raw  # value slot 0
    data = bytes([0x18]) + payload.to_bytes(7, "little")
    dec.feed(CanFrame(0x6F2, data))
    approx(st.module_temps[0], -820 * 0.0122, 1e-9)


def test_382_energy_and_health():
    st, dec = fresh()
    data = SimulatorSource._enc_energy(nominal_full=74.3, remaining=58.0)
    dec.feed(CanFrame(0x382, data))
    approx(st.num("nominal_full_energy"), 74.3, 0.11)
    approx(st.num("nominal_remaining"), 58.0, 0.11)
    st.recompute_derived(pack_new_kwh=81.5)
    approx(st.num("battery_health"), 74.3 / 81.5 * 100, 0.2)


def test_di_torque_frames():
    st, dec = fresh()
    dec.feed(CanFrame(0x106, SimulatorSource._enc_di_torque1(rpm=7250, pedal=42.0)))
    approx(st.num("motor_rpm"), 7250, 1)
    approx(st.num("pedal_position"), 42.0, 0.4)
    dec.feed(CanFrame(0x116, SimulatorSource._enc_di_torque2(speed_mph=65.0, gear=4)))
    approx(st.num("vehicle_speed"), 65.0, 0.05)
    assert st.get("gear") == "D"


def test_serial_number_assembly():
    st, dec = fresh()
    dec.feed(CanFrame(0x542, b"T12S0123"))
    dec.feed(CanFrame(0x552, b"456789\x00\x00"))
    assert st.get("serial_number") == "T12S0123456789"
    # non-printable frames must be ignored
    dec.feed(CanFrame(0x542, bytes([0x01, 0x02, 0xFF])))
    assert st.get("serial_number") == "T12S0123456789"


def test_bits_le():
    # DBC Intel extraction: bits 16-27 of 03 E8 pattern
    d = bytes([0, 0, 0xE8, 0x03, 0, 0, 0, 0])
    assert bits_le(d, 16, 12) == 0x3E8
    assert bits_le(bytes([0, 0, 0xFF, 0x0F, 0, 0, 0, 0]), 16, 12, signed=True) == -1


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
