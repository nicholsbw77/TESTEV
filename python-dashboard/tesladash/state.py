"""Live vehicle state: latest value per signal + short history for sparklines.

Only ever touched from the GUI thread (CAN sources hand frames over through a
queue; see app.py), so no locking is needed here.
"""

import math
import time
from collections import deque

NAN = float("nan")

HISTORY_SECONDS = 1800     # 30 min of sparkline history
HISTORY_SAMPLE_S = 1.0     # one sample per second


def is_num(v) -> bool:
    return isinstance(v, (int, float)) and not (isinstance(v, float) and math.isnan(v))


class VehicleState:
    def __init__(self):
        self.values: dict[str, object] = {}
        self.stamps: dict[str, float] = {}
        # history[name] = deque[(t, value)]
        self.history: dict[str, deque] = {}
        self._last_sample = 0.0

        # Cell-level arrays (fed by the 0x6F2 sweep decoder)
        self.cells: list[float] = [NAN] * 96          # cell voltages, V
        self.module_temps: list[float] = [NAN] * 32   # 2 sensors x 16 modules, degC

        self.connected = False
        self.source_desc = ""

    # ── value access ────────────────────────────────────────────────────

    def set(self, name: str, value) -> None:
        self.values[name] = value
        self.stamps[name] = time.time()

    def get(self, name: str, default=NAN):
        return self.values.get(name, default)

    def num(self, name: str) -> float:
        v = self.values.get(name)
        return float(v) if is_num(v) else NAN

    def age(self, name: str) -> float:
        """Seconds since this signal last updated (inf if never seen)."""
        t = self.stamps.get(name)
        return time.time() - t if t else float("inf")

    # ── derived values, recomputed after each batch of frames ───────────

    def recompute_derived(self, pack_new_kwh: float) -> None:
        v, i = self.num("pack_voltage"), self.num("pack_current")
        if is_num(v) and is_num(i):
            self.set("pack_power", v * i / 1000.0)

        valid = [c for c in self.cells if is_num(c) and c > 0.5]
        if valid:
            cmin, cmax = min(valid), max(valid)
            self.set("cell_min", cmin)
            self.set("cell_max", cmax)
            self.set("cell_avg", sum(valid) / len(valid))
            if len(valid) >= 2:
                self.set("cell_delta_mv", (cmax - cmin) * 1000.0)

        temps = [t for t in self.module_temps if is_num(t)]
        if temps:
            self.set("batt_temp_min", min(temps))
            self.set("batt_temp_max", max(temps))
            self.set("batt_temp_avg", sum(temps) / len(temps))

        nfe = self.num("nominal_full_energy")
        if is_num(nfe) and pack_new_kwh > 0:
            self.set("battery_health", min(100.0, nfe / pack_new_kwh * 100.0))

    def cell_avg_or_nan(self) -> float:
        valid = [c for c in self.cells if is_num(c) and c > 0.5]
        return sum(valid) / len(valid) if valid else NAN

    # ── history ─────────────────────────────────────────────────────────

    def sample_history(self) -> None:
        now = time.time()
        if now - self._last_sample < HISTORY_SAMPLE_S:
            return
        self._last_sample = now
        maxlen = int(HISTORY_SECONDS / HISTORY_SAMPLE_S)
        for name, value in self.values.items():
            if not is_num(value):
                continue
            dq = self.history.get(name)
            if dq is None:
                dq = self.history[name] = deque(maxlen=maxlen)
            dq.append((now, float(value)))
