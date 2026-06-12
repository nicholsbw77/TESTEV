"""Tesla Model S (2013) CAN decoders.

Two provenance tiers, kept deliberately separate:

1. VERIFIED — direct ports of lib/can/pack_state.dart from this repo's
   Flutter app, whose scaling/endianness were fixed against raw captures
   from the actual car (see git history: "Fix CAN decode from raw vehicle
   bus capture analysis"). IDs: 0x6F2, 0x132/0x102, 0x202, 0x232, 0x302,
   0x332, 0x392, 0x542/0x552, 0x7E2.

2. COMMUNITY — Model S powertrain-bus decodes from the community DBC
   lineage (tesla_models_awd.dbc / opendbc tesla_can.dbc). Marked
   unverified in signals.py; confirm against your own candump before
   trusting. IDs: 0x106/0x108, 0x116/0x118, 0x154, 0x1D4, 0x210, 0x266,
   0x2E5, 0x382, 0x3D2, 0x562.

Bus profiles (mirrors the Flutter app's `vehicleBus` flag):
  vehicle — OBD/diagnostic connector bus. 0x102/0x202/0x232/0x302/0x542/
            0x552 do NOT exist here; pack V/I arrives as 0x132, SoC as
            0x332, limits as muxed 0x392.
  bms     — BMS internal bus (bench/direct pack connection).
"""

import time

from .frames import CanFrame
from .signals import GEAR_NAMES
from .state import VehicleState, is_num

NAN = float("nan")


def be16(d: bytes, i: int) -> int:
    return (d[i] << 8) | d[i + 1]


def bits_le(d: bytes, start: int, length: int, signed: bool = False) -> int:
    """DBC-style little-endian (Intel, @1) signal extraction."""
    raw = int.from_bytes(d.ljust(8, b"\x00"), "little")
    val = (raw >> start) & ((1 << length) - 1)
    if signed and val & (1 << (length - 1)):
        val -= 1 << length
    return val


class TeslaDecoder:
    def __init__(self, state: VehicleState, vehicle_bus: bool = True):
        self.state = state
        self.vehicle_bus = vehicle_bus

        # 0x6F2 sweep buffers (port of PackState.feed6F2)
        self._mux_seen: set[int] = set()
        self._sweep_cells = [NAN] * 96
        self._sweep_temps = [NAN] * 32
        self._sweep_start = time.time()

        self._serial_lo = ""
        self._serial_hi = ""

        # frame-rate accounting
        self._frame_count = 0
        self._fps_time = time.time()

    # ── dispatch ─────────────────────────────────────────────────────────

    def feed(self, frame: CanFrame) -> None:
        self._count_frame()
        handler = self._DISPATCH.get(frame.id)
        if handler:
            handler(self, frame.data)

    def _count_frame(self) -> None:
        self._frame_count += 1
        now = time.time()
        if now - self._fps_time >= 1.0:
            self.state.set("frame_rate", self._frame_count / (now - self._fps_time))
            self._frame_count = 0
            self._fps_time = now

    # ── VERIFIED: pack voltage / current (0x132 vehicle bus, 0x102 BMS bus) ──

    def feed_132(self, d: bytes) -> None:
        if len(d) < 2:
            return
        self.state.set("pack_voltage", be16(d, 0) * 0.01)
        if len(d) >= 4:
            raw_i = be16(d, 2)
            if raw_i in (0xFFFF, 0x7FFF):
                self.state.set("pack_current", NAN)
            else:
                signed = raw_i - 0x10000 if raw_i > 0x7FFF else raw_i
                self.state.set("pack_current", signed * 0.1)

    def feed_102(self, d: bytes) -> None:
        if not self.vehicle_bus:   # 0x102 only trustworthy on the BMS internal bus
            self.feed_132(d)

    # ── VERIFIED: BMS internal bus only ──────────────────────────────────

    def feed_202(self, d: bytes) -> None:
        if self.vehicle_bus or len(d) < 8:
            return
        self.state.set("max_charge_current", be16(d, 4) * 0.1)
        self.state.set("max_discharge_current", be16(d, 6) * 0.1)

    def feed_232(self, d: bytes) -> None:
        if self.vehicle_bus or len(d) < 4:
            return
        self.state.set("max_regen_kw", be16(d, 0) * 0.01)
        self.state.set("max_discharge_kw", be16(d, 2) * 0.01)

    def feed_302(self, d: bytes) -> None:
        if len(d) < 8:
            return
        # SoC/SoE only reliable on the BMS internal bus — on the vehicle bus
        # 0x302 originates elsewhere / is multiplexed.
        if not self.vehicle_bus:
            raw_soc, raw_soe = be16(d, 0), be16(d, 2)
            if 0 < raw_soc and raw_soc * 0.01 <= 100.0:
                self.state.set("soc", raw_soc * 0.01)
            if 0 < raw_soe and raw_soe * 0.01 <= 100.0:
                self.state.set("soc_energy", raw_soe * 0.01)
        # kWh counter: bytes 4-6 big-endian, monotonic guard against glitches
        kwh_raw = (d[4] << 16) | (d[5] << 8) | d[6]
        if kwh_raw > 0:
            cand = kwh_raw * 0.01
            prev = self.state.num("kwh_charged")
            if cand < 500000 and (not is_num(prev) or (prev <= cand < prev + 500)):
                self.state.set("kwh_charged", cand)

    # ── VERIFIED: vehicle-bus SoC with cell-average cross-check (0x332) ──

    def feed_332(self, d: bytes) -> None:
        if len(d) < 3:
            return
        avg = self.state.cell_avg_or_nan()
        if not is_num(avg):
            return
        est_soc = max(0.0, min(100.0, (avg - 3.0) / 1.2 * 100.0))
        # Try bytes [0:1] (non-muxed) then [1:2] (muxed, byte 0 = mux counter)
        for raw in (be16(d, 0), be16(d, 1)):
            if raw > 0:
                cand = raw * 0.01
                if 0.0 < cand <= 100.0 and abs(cand - est_soc) < 30:
                    self.state.set("soc", cand)
                    return

    # ── VERIFIED: vehicle-bus power limits, muxed by byte 0 (0x392) ──────

    def feed_392(self, d: bytes) -> None:
        if len(d) < 7:
            return
        mux = d[0] & 0x0F
        if mux == 0x01:
            # kW limits, bytes BE x0.01; reject transitional zero-ish frames
            raw_dis = be16(d, 1)
            if raw_dis > 1000:
                self.state.set("max_discharge_kw", raw_dis * 0.01)
            raw_regen = be16(d, 4)
            if raw_regen > 1000:
                self.state.set("max_regen_kw", raw_regen * 0.01)
        elif mux == 0x04:
            # current limits, bytes [4:5] LE x0.1 A
            raw_i = d[4] | (d[5] << 8)
            if 0 < raw_i < 0xFFFF:
                self.state.set("max_discharge_current", raw_i * 0.1)
                self.state.set("wot_current_limit", raw_i * 0.1)

    # ── VERIFIED: pack serial (BMS internal bus) ─────────────────────────

    @staticmethod
    def _ascii(d: bytes) -> str | None:
        trimmed = bytes(b for b in d if b != 0)
        if not trimmed or any(not (0x20 <= b <= 0x7E) for b in trimmed):
            return None
        return trimmed.decode("ascii")

    def feed_542(self, d: bytes) -> None:
        s = self._ascii(d)
        if s is not None:
            self._serial_lo = s
            self.state.set("serial_number", self._serial_lo + self._serial_hi)

    def feed_552(self, d: bytes) -> None:
        s = self._ascii(d)
        if s is not None:
            self._serial_hi = s
            self.state.set("serial_number", self._serial_lo + self._serial_hi)

    def feed_7E2(self, d: bytes) -> None:
        if len(d) >= 6 and d[0] == 0x89:
            self.state.set("wot_current_limit", be16(d, 4) * 0.12)

    # ── VERIFIED: 0x6F2 cell-voltage / module-temp sweep ─────────────────
    # Mux byte 0: 0x00-0x17 carry 4 cell voltages each (96 cells),
    # 0x18-0x1F carry 4 temp sensors each (16 modules x 2 sensors).
    # Payload: 56-bit little-endian field of 4x 14-bit values.

    def feed_6F2(self, d: bytes) -> None:
        if len(d) < 8:
            return
        mux = d[0]
        if mux > 0x1F:
            return

        raw = int.from_bytes(d[1:8], "little")
        values = [(raw >> (i * 14)) & 0x3FFF for i in range(4)]
        st = self.state

        if mux <= 0x17:
            base = mux * 4
            for i, v in enumerate(values):
                idx = base + i
                if idx < 96:
                    # 0x6F2 uses 5.0V full-scale: 0.000305 V/count
                    volt = v * 0.000305
                    self._sweep_cells[idx] = volt
                    # incremental update so slow links show data immediately
                    if 0.5 < volt < 5.0:
                        st.cells[idx] = volt
        else:
            base = (mux - 0x18) * 4
            for i, v in enumerate(values):
                idx = base + i
                if idx < 32:
                    if v & 0x2000:
                        v -= 0x4000
                    temp = v * 0.0122       # signed 14-bit, 0.0122 degC/bit
                    self._sweep_temps[idx] = temp
                    st.module_temps[idx] = temp

        # reset a stale sweep that never completed
        now = time.time()
        if self._mux_seen and now - self._sweep_start > 10:
            self._mux_seen.clear()
            self._sweep_cells[:] = [NAN] * 96
            self._sweep_temps[:] = [NAN] * 32
        if not self._mux_seen:
            self._sweep_start = now
        self._mux_seen.add(mux)

        if len(self._mux_seen) >= 32:
            # complete sweep — atomic update with sanity filter
            for i, v in enumerate(self._sweep_cells):
                if is_num(v) and 0.5 < v < 5.0:
                    st.cells[i] = v
            st.module_temps[:] = self._sweep_temps
            self._mux_seen.clear()
            self._sweep_cells[:] = [NAN] * 96
            self._sweep_temps[:] = [NAN] * 32

    # ── COMMUNITY: drive unit (verify on your car) ───────────────────────
    # Pre-AP cars are reported to use 0x106/0x116; AP1-era DBCs list the
    # same layouts at 0x108/0x118. Both are registered; whichever exists
    # on your bus feeds the signals.

    def feed_di_torque1(self, d: bytes) -> None:
        if len(d) < 8:
            return
        rpm = bits_le(d, 32, 16, signed=True)
        self.state.set("motor_rpm", abs(rpm))
        self.state.set("pedal_position", d[6] * 0.4)

    def feed_di_torque2(self, d: bytes) -> None:
        if len(d) < 6:
            return
        self.state.set("vehicle_speed", bits_le(d, 16, 12) * 0.05 - 25.0)
        self.state.set("gear", GEAR_NAMES.get(bits_le(d, 12, 3), "?"))

    def feed_154(self, d: bytes) -> None:
        if len(d) >= 7:
            self.state.set("rear_torque", float(bits_le(d, 40, 13, signed=True)))

    def feed_1D4(self, d: bytes) -> None:
        if len(d) >= 7:
            self.state.set("front_torque", float(bits_le(d, 40, 13, signed=True)))

    def _feed_du_power(self, d: bytes, prefix: str) -> None:
        if len(d) < 8:
            return
        self.state.set(prefix + "_inv_dissipation", d[1] * 125 / 1000.0)  # kW
        self.state.set(prefix + "_mech_power", bits_le(d, 16, 11, signed=True) * 0.5)
        self.state.set(prefix + "_stator_current", float(bits_le(d, 32, 11)))

    def feed_266(self, d: bytes) -> None:
        self._feed_du_power(d, "rear")

    def feed_2E5(self, d: bytes) -> None:
        self._feed_du_power(d, "front")

    # ── COMMUNITY: DC-DC converter (0x210) ───────────────────────────────

    def feed_210(self, d: bytes) -> None:
        if len(d) < 7:
            return
        raw_t = bits_le(d, 16, 8, signed=True)
        self.state.set("dcdc_inlet_temp", raw_t * 0.5 + 40.0)
        self.state.set("dcdc_input_power", d[3] * 16.0)
        self.state.set("dcdc_output_current", float(d[4]))
        self.state.set("dcdc_output_voltage", d[5] * 0.1)

    # ── COMMUNITY: battery energy / health (0x382), lifetime (0x3D2),
    #    odometer (0x562) ──────────────────────────────────────────────────

    def feed_382(self, d: bytes) -> None:
        if len(d) < 8:
            return
        fields = (
            ("nominal_full_energy", 0),
            ("nominal_remaining", 10),
            ("expected_remaining", 20),
        )
        for name, start in fields:
            val = bits_le(d, start, 10) * 0.1
            if 0 < val < 120:           # sanity: kWh
                self.state.set(name, val)
        buf = bits_le(d, 50, 8) * 0.1
        if buf < 25:
            self.state.set("energy_buffer", buf)

    def feed_3D2(self, d: bytes) -> None:
        if len(d) < 8:
            return
        self.state.set("lifetime_discharge_kwh", bits_le(d, 0, 32) / 1000.0)
        self.state.set("lifetime_charge_kwh", bits_le(d, 32, 32) / 1000.0)

    def feed_562(self, d: bytes) -> None:
        if len(d) >= 4:
            self.state.set("odometer", bits_le(d, 0, 32) * 0.001)

    _DISPATCH = {
        0x6F2: feed_6F2,
        0x102: feed_102,
        0x132: feed_132,
        0x202: feed_202,
        0x232: feed_232,
        0x302: feed_302,
        0x332: feed_332,
        0x392: feed_392,
        0x542: feed_542,
        0x552: feed_552,
        0x7E2: feed_7E2,
        0x106: feed_di_torque1,
        0x108: feed_di_torque1,
        0x116: feed_di_torque2,
        0x118: feed_di_torque2,
        0x154: feed_154,
        0x1D4: feed_1D4,
        0x210: feed_210,
        0x266: feed_266,
        0x2E5: feed_2E5,
        0x382: feed_382,
        0x3D2: feed_3D2,
        0x562: feed_562,
    }


#: IDs worth hardware-filtering for on bandwidth-limited adapters
#: (ELM327/STN monitor mode). SocketCAN needs no filter.
VEHICLE_BUS_IDS = sorted(TeslaDecoder._DISPATCH.keys())
