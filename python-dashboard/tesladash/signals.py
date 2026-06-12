"""Catalog of every dashboard signal the decoders can produce.

`verified=True`  → decode ported from this repo's Flutter app, which was
                   validated against raw CAN captures from the actual car
                   (2013 Model S, OBDLink MX+ / MeatPi WiCAN).
`verified=False` → community reverse-engineered decode (Model S powertrain
                   CAN3 DBC / opendbc tesla_can.dbc lineage). Treat as a
                   starting point and verify against your own capture before
                   trusting the number — Tesla changed layouts across years
                   and firmware versions.

The dashboard's "Add tile" dialog reads this catalog, so adding a new signal
here (plus a decoder in decoders.py) makes it immediately available in the UI.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class SignalSpec:
    name: str            # internal key, e.g. "pack_voltage"
    label: str           # human label shown on tiles
    unit: str            # display unit
    decimals: int = 1
    lo: float = 0.0      # default gauge/bar range
    hi: float = 100.0
    warn_lo: float | None = None   # value below this draws in warning color
    warn_hi: float | None = None   # value above this draws in warning color
    verified: bool = False
    source: str = ""     # where the decode comes from (shown in Add-tile dialog)
    text: bool = False   # string-valued signal (serial number, gear, ...)


def _s(*args, **kw) -> SignalSpec:
    return SignalSpec(*args, **kw)


SIGNALS: dict[str, SignalSpec] = {s.name: s for s in [
    # ── Battery pack — verified decoders (0x132/0x102, 0x332, 0x392, 0x6F2) ──
    _s("pack_voltage", "Pack Voltage", "V", 1, 250, 420, warn_lo=290,
       verified=True, source="0x132/0x102 bytes[0:1] BE x0.01 (capture-verified)"),
    _s("pack_current", "Pack Current", "A", 1, -400, 1200, warn_hi=900,
       verified=True, source="0x132/0x102 bytes[2:3] BE s16 x0.1 (capture-verified)"),
    _s("pack_power", "Pack Power", "kW", 1, -80, 400, warn_hi=320,
       verified=True, source="computed: pack_voltage x pack_current"),
    _s("soc", "State of Charge", "%", 1, 0, 100, warn_lo=10,
       verified=True, source="0x332 (vehicle bus) / 0x302 (BMS bus), cross-checked vs cell avg"),
    _s("soc_energy", "State of Energy", "%", 1, 0, 100,
       verified=True, source="0x302 bytes[2:3] BE x0.01 (BMS internal bus only)"),
    _s("max_discharge_kw", "Max Discharge", "kW", 0, 0, 700,
       verified=True, source="0x392 mux 01 bytes[1:2] BE x0.01 / 0x232 (BMS bus)"),
    _s("max_regen_kw", "Max Regen", "kW", 0, 0, 700,
       verified=True, source="0x392 mux 01 bytes[4:5] BE x0.01 / 0x232 (BMS bus)"),
    _s("max_discharge_current", "Max Discharge Current", "A", 0, 0, 5000,
       verified=True, source="0x392 mux 04 bytes[4:5] LE x0.1 / 0x202 (BMS bus)"),
    _s("max_charge_current", "Max Charge Current", "A", 0, 0, 500,
       verified=True, source="0x202 bytes[4:5] BE x0.1 (BMS internal bus only)"),
    _s("wot_current_limit", "WOT Current Limit", "A", 0, 0, 5000,
       verified=True, source="0x392 mux 04 / 0x7E2 (0x89) bytes[4:5] BE x0.12"),
    _s("kwh_charged", "Lifetime Charged", "kWh", 0, 0, 100000,
       verified=True, source="0x302 bytes[4:6] BE x0.01 (BMS internal bus only)"),

    # ── Cells & battery temperature — verified 0x6F2 sweep ──
    _s("cell_min", "Cell Min", "V", 3, 2.8, 4.3, warn_lo=3.1,
       verified=True, source="0x6F2 mux 00-17, 14-bit x0.000305 V"),
    _s("cell_max", "Cell Max", "V", 3, 2.8, 4.3, warn_hi=4.2,
       verified=True, source="0x6F2 mux 00-17"),
    _s("cell_avg", "Cell Avg", "V", 3, 2.8, 4.3,
       verified=True, source="0x6F2 mux 00-17"),
    _s("cell_delta_mv", "Cell Imbalance", "mV", 0, 0, 150, warn_hi=50,
       verified=True, source="0x6F2 (max-min cell), key pack-health indicator"),
    _s("batt_temp_min", "Battery Temp Min", "\N{DEGREE SIGN}C", 1, -20, 60, warn_hi=45,
       verified=True, source="0x6F2 mux 18-1F, 14-bit signed x0.0122 degC"),
    _s("batt_temp_max", "Battery Temp Max", "\N{DEGREE SIGN}C", 1, -20, 60, warn_hi=45,
       verified=True, source="0x6F2 mux 18-1F"),
    _s("batt_temp_avg", "Battery Temp", "\N{DEGREE SIGN}C", 1, -20, 60, warn_hi=45, warn_lo=0,
       verified=True, source="0x6F2 mux 18-1F (average of 32 module sensors)"),

    # ── Battery health & energy — community DBC (verify on your car) ──
    _s("nominal_full_energy", "Nominal Full Pack", "kWh", 1, 0, 90,
       source="0x382 Battery_Energy_Status bits 0-9 LE x0.1 (community DBC)"),
    _s("nominal_remaining", "Energy Remaining", "kWh", 1, 0, 90,
       source="0x382 bits 10-19 LE x0.1 (community DBC)"),
    _s("expected_remaining", "Expected Remaining", "kWh", 1, 0, 90,
       source="0x382 bits 20-29 LE x0.1 (community DBC)"),
    _s("energy_buffer", "Energy Buffer", "kWh", 1, 0, 10,
       source="0x382 bits 50-57 LE x0.1 (community DBC)"),
    _s("battery_health", "Battery Health", "%", 1, 50, 100, warn_lo=80,
       source="computed: nominal_full_energy / pack_new_kwh (config)"),
    _s("lifetime_discharge_kwh", "Lifetime Discharge", "kWh", 0, 0, 200000,
       source="0x3D2 bits 0-31 LE Wh (community DBC)"),
    _s("lifetime_charge_kwh", "Lifetime Charge", "kWh", 0, 0, 200000,
       source="0x3D2 bits 32-63 LE Wh (community DBC)"),
    _s("odometer", "Battery Odometer", "mi", 0, 0, 500000,
       source="0x562 bits 0-31 LE x0.001 mi (community DBC)"),

    # ── Drive unit / motor — community DBC (verify on your car) ──
    _s("motor_rpm", "Motor RPM", "rpm", 0, 0, 16000, warn_hi=15000,
       source="0x106/0x108 bytes[4:5] LE s16 (community DBC, pre-AP uses 0x106)"),
    _s("vehicle_speed", "Speed", "mph", 0, 0, 140,
       source="0x116/0x118 bits 16-27 LE x0.05 -25 (community DBC)"),
    _s("gear", "Gear", "", 0, 0, 4, text=True,
       source="0x116/0x118 bits 12-14 (1=P 2=R 3=N 4=D, community DBC)"),
    _s("pedal_position", "Accelerator", "%", 0, 0, 100,
       source="0x106/0x108 byte[6] x0.4 (community DBC)"),
    _s("rear_torque", "Rear Torque", "Nm", 0, -200, 700,
       source="0x154 bits 40-52 LE s13 (community DBC; scale approx.)"),
    _s("front_torque", "Front Torque", "Nm", 0, -200, 700,
       source="0x1D4 bits 40-52 LE s13 (community DBC; AWD cars only)"),

    # ── Inverter — community DBC. NOTE: Model S DI does not broadcast
    #    inverter/stator temperature on a publicly documented frame; the
    #    dissipation signal below is the best passive thermal proxy until a
    #    temp frame is identified from capture (see README). ──
    _s("rear_inv_dissipation", "Rear Inv Dissipation", "kW", 2, 0, 30, warn_hi=20,
       source="0x266 byte[1] x125 W (community DBC) — thermal-load proxy"),
    _s("rear_mech_power", "Rear Mech Power", "kW", 0, -100, 400,
       source="0x266 bits 16-26 LE s11 x0.5 (community DBC)"),
    _s("rear_stator_current", "Rear Stator Current", "A", 0, 0, 1300, warn_hi=1100,
       source="0x266 bits 32-42 LE x1 (community DBC)"),
    _s("front_inv_dissipation", "Front Inv Dissipation", "kW", 2, 0, 30, warn_hi=20,
       source="0x2E5 byte[1] x125 W (community DBC; AWD cars only)"),
    _s("front_mech_power", "Front Mech Power", "kW", 0, -100, 400,
       source="0x2E5 bits 16-26 LE s11 x0.5 (community DBC; AWD cars only)"),
    _s("front_stator_current", "Front Stator Current", "A", 0, 0, 1300,
       source="0x2E5 bits 32-42 LE x1 (community DBC; AWD cars only)"),

    # ── Thermal / DC-DC — community DBC ──
    _s("dcdc_inlet_temp", "Coolant Inlet (DC-DC)", "\N{DEGREE SIGN}C", 1, -20, 90, warn_hi=60,
       source="0x210 byte[2] s8 x0.5 +40 (community DBC; offset sign unverified)"),
    _s("dcdc_output_voltage", "12V Rail", "V", 1, 9, 16, warn_lo=11.5, warn_hi=15,
       source="0x210 byte[5] x0.1 (community DBC)"),
    _s("dcdc_output_current", "DC-DC Current", "A", 0, 0, 250,
       source="0x210 byte[4] x1 (community DBC)"),
    _s("dcdc_input_power", "DC-DC Input", "W", 0, 0, 3000,
       source="0x210 byte[3] x16 (community DBC)"),

    # ── Identity / link diagnostics ──
    _s("serial_number", "Pack Serial", "", 0, text=True,
       verified=True, source="0x542/0x552 ASCII (BMS internal bus only)"),
    _s("frame_rate", "CAN Frames", "fps", 0, 0, 2000,
       verified=True, source="link statistic"),
]}


GEAR_NAMES = {0: "?", 1: "P", 2: "R", 3: "N", 4: "D"}
