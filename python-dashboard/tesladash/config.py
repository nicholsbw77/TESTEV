"""Dashboard layout + app settings, persisted as JSON.

Default path: ~/.config/tesladash/layout.json (override with --config).
The file is human-editable; the in-app edit mode writes the same format.
"""

import json
import os
from dataclasses import dataclass, field, asdict

from .signals import SIGNALS

DEFAULT_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "tesladash", "layout.json")

TILE_TYPES = ("gauge", "bar", "number", "sparkline", "cellgrid", "modtable",
              "packdelta", "modtemps", "status")


@dataclass
class TileConfig:
    type: str                     # one of TILE_TYPES
    signal: str = ""              # key into signals.SIGNALS ("" for cellgrid etc.)
    title: str = ""               # override label ("" = use catalog label)
    lo: float | None = None       # override gauge range
    hi: float | None = None
    span: int = 1                 # grid columns this tile occupies

    def spec(self):
        return SIGNALS.get(self.signal)


@dataclass
class DashConfig:
    columns: int = 4
    pack_new_kwh: float = 81.5    # S85 usable-when-new; set 58.5 for a 60
    metric: bool = False          # show km/h & km instead of mph & mi
    tiles: list = field(default_factory=list)

    def to_json(self) -> str:
        return json.dumps(
            {"columns": self.columns, "pack_new_kwh": self.pack_new_kwh,
             "metric": self.metric, "tiles": [asdict(t) for t in self.tiles]},
            indent=2)

    @staticmethod
    def from_json(text: str) -> "DashConfig":
        raw = json.loads(text)
        cfg = DashConfig(
            columns=int(raw.get("columns", 4)),
            pack_new_kwh=float(raw.get("pack_new_kwh", 81.5)),
            metric=bool(raw.get("metric", False)))
        for t in raw.get("tiles", []):
            if t.get("type") in TILE_TYPES:
                cfg.tiles.append(TileConfig(
                    type=t["type"], signal=t.get("signal", ""),
                    title=t.get("title", ""), lo=t.get("lo"), hi=t.get("hi"),
                    span=int(t.get("span", 1))))
        return cfg


def default_config() -> DashConfig:
    """Battery-health-centric default layout for a 2013 Model S."""
    T = TileConfig
    return DashConfig(columns=4, tiles=[
        T("gauge", "soc"),
        T("gauge", "pack_power"),
        T("gauge", "vehicle_speed"),
        T("gauge", "motor_rpm"),
        T("number", "pack_voltage"),
        T("number", "pack_current"),
        T("number", "battery_health"),
        T("number", "nominal_full_energy"),
        T("sparkline", "batt_temp_avg"),
        T("sparkline", "rear_inv_dissipation"),
        T("number", "dcdc_inlet_temp"),
        T("number", "dcdc_output_voltage"),
        T("modtable", span=2),
        T("packdelta", span=1),
        T("status", span=1),
        T("bar", "cell_delta_mv"),
        T("bar", "max_discharge_kw"),
        T("number", "max_regen_kw"),
        T("number", "odometer"),
    ])


def bench_config() -> DashConfig:
    """Bench-tester layout: module/brick table front and center, matching the
    Flutter app's bench screen. Use with --config layouts/bench.json."""
    T = TileConfig
    return DashConfig(columns=4, tiles=[
        T("packdelta"),
        T("number", "soc"),
        T("number", "pack_voltage"),
        T("number", "pack_current"),
        T("modtable", span=3),
        T("cellgrid", span=1),
        T("modtemps"),
        T("number", "max_discharge_kw", title="Max kW"),
        T("number", "wot_current_limit", title="WOT A"),
        T("number", "kwh_charged"),
        T("bar", "cell_delta_mv"),
        T("sparkline", "cell_min"),
        T("sparkline", "batt_temp_avg"),
        T("status"),
    ])


def load(path: str = DEFAULT_PATH) -> DashConfig:
    try:
        with open(path) as f:
            return DashConfig.from_json(f.read())
    except (OSError, ValueError, KeyError):
        return default_config()


def save(cfg: DashConfig, path: str = DEFAULT_PATH) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(cfg.to_json())
    os.replace(tmp, path)
