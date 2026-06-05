"""
logging_/csv_logger.py — Unified CSV session logger.

Writes one row per full data sweep to a timestamped CSV file.
Also maintains the legacy bmb_module_log.csv format for backward
compatibility with the existing SummaryTab.
"""

from __future__ import annotations

import csv
import datetime
import math
import os
import time
from pathlib import Path
from typing import Optional

from config import LOG_DIR, SESSION_LOG_SUFFIX, INFO_LOG_SUFFIX
from model.pack_state import PackState, _valid


# ── Column definitions ────────────────────────────────────────────────────────

_HEADER = (
    ["timestamp", "source", "pack_v", "pack_i", "soc_pct",
     "isolation_kohm", "kwh_charged", "kwh_discharged",
     "contactor_state", "neg_term_temp_c",
     "cell_v_min", "cell_v_max", "cell_v_delta",
     "balance_active"]
    + [f"cell_{i+1:02d}" for i in range(96)]
    + [f"mod_{m+1:02d}_v" for m in range(16)]
    + [f"mod_{m+1:02d}_t1" for m in range(16)]
    + [f"mod_{m+1:02d}_t2" for m in range(16)]
    + ["alerts"]
)


def _fmt(v: float, decimals: int = 4) -> str:
    if not _valid(v):
        return ""
    return f"{v:.{decimals}f}"


class SessionLogger:
    """
    Opens a session CSV on creation; call log_state() to append rows;
    call close() (or use as context manager) to finalize.
    """

    def __init__(self, mode: str = "can"):
        """
        mode: "can" | "serial" | "dual"
        """
        self._mode = mode
        self._start_time = time.time()
        self._rows_written = 0
        self._first_state: Optional[PackState] = None
        self._last_state: Optional[PackState] = None

        # Ensure log directory exists
        log_dir = Path(LOG_DIR)
        log_dir.mkdir(parents=True, exist_ok=True)

        ts = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
        self._csv_path = log_dir / f"{ts}_{mode}{SESSION_LOG_SUFFIX}"
        self._info_path = log_dir / f"{ts}_{mode}{INFO_LOG_SUFFIX}"

        self._file = open(self._csv_path, "w", newline="", encoding="utf-8")
        self._writer = csv.writer(self._file)
        self._writer.writerow(_HEADER)
        self._file.flush()

    def log_state(self, state: PackState) -> None:
        """Append one row from a PackState snapshot."""
        if self._first_state is None:
            self._first_state = state
        self._last_state = state

        ts = datetime.datetime.fromtimestamp(state.timestamp).isoformat(timespec="milliseconds")
        bal_active = any(m != 0 for m in state.balance_masks.values())
        alert_codes = "|".join(a.code for a in state.unexpected_alerts)

        row = (
            [ts, state.mode_label,
             _fmt(state.pack_voltage, 2),
             _fmt(state.pack_current, 2),
             _fmt(state.soc_percent, 1),
             _fmt(state.isolation_kohm, 0),
             _fmt(state.kwh_charged, 2),
             _fmt(state.kwh_discharged, 2),
             state.contactor_state,
             _fmt(state.neg_terminal_temp_c, 1),
             _fmt(state.cell_v_min, 4),
             _fmt(state.cell_v_max, 4),
             _fmt(state.cell_v_delta * 1000, 2),   # convert to mV
             "1" if bal_active else "0"]
            + [_fmt(v) for v in state.cell_voltages]
            + [_fmt(v, 3) for v in state.module_voltages]
            + [_fmt(state.module_temps[m][0], 1) for m in range(16)]
            + [_fmt(state.module_temps[m][1], 1) for m in range(16)]
            + [alert_codes]
        )
        self._writer.writerow(row)
        self._file.flush()
        self._rows_written += 1

    def close(self) -> Path:
        """Close the CSV and write the session info file. Returns CSV path."""
        self._file.close()
        self._write_info()
        return self._csv_path

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _write_info(self) -> None:
        duration = time.time() - self._start_time
        m, s = divmod(int(duration), 60)

        with open(self._info_path, "w", encoding="utf-8") as f:
            f.write(f"Tesla BMS Bench Tester — Session Summary\n")
            f.write(f"{'='*50}\n\n")
            f.write(f"Mode:           {self._mode}\n")
            f.write(f"Start:          {datetime.datetime.fromtimestamp(self._start_time)}\n")
            f.write(f"Duration:       {m}m {s}s\n")
            f.write(f"Rows logged:    {self._rows_written}\n\n")

            if self._first_state and self._last_state:
                f0, f1 = self._first_state, self._last_state
                f.write(f"Pack voltage:   {_fmt(f0.pack_voltage,2)} V → {_fmt(f1.pack_voltage,2)} V\n")
                f.write(f"SoC:            {_fmt(f0.soc_percent,1)} % → {_fmt(f1.soc_percent,1)} %\n")
                f.write(f"kWh charged:    {_fmt(f1.kwh_charged,2)}\n")
                f.write(f"kWh discharged: {_fmt(f1.kwh_discharged,2)}\n\n")

                # Cell stats across the entire session
                all_mins = []
                all_maxs = []
                f.write(f"Cell V start:   min={_fmt(f0.cell_v_min)} max={_fmt(f0.cell_v_max)} "
                        f"delta={_fmt(f0.cell_v_delta*1000,1)}mV\n")
                f.write(f"Cell V end:     min={_fmt(f1.cell_v_min)} max={_fmt(f1.cell_v_max)} "
                        f"delta={_fmt(f1.cell_v_delta*1000,1)}mV\n\n")

                if f1.unexpected_alerts:
                    f.write("Unexpected alerts:\n")
                    for a in f1.unexpected_alerts:
                        f.write(f"  [{a.source}] {a.code}: {a.description}\n")
                else:
                    f.write("No unexpected alerts.\n")

    @property
    def csv_path(self) -> Path:
        return self._csv_path

    @property
    def rows_written(self) -> int:
        return self._rows_written


# ── Legacy module log (backward compat with bmb_gui.py SummaryTab) ────────────

LEGACY_LOG_DIR  = "tesla_bms_logs"
LEGACY_LOG_FILE = "bmb_module_log.csv"
LEGACY_FIELDS = [
    "timestamp", "module_label", "serial_num", "hw_addr",
    "cell1_V", "cell2_V", "cell3_V", "cell4_V", "cell5_V", "cell6_V",
    "module_V", "temp1_C", "temp2_C", "spread_mV", "avg_V",
]

def ensure_legacy_log() -> Path:
    p = Path(LEGACY_LOG_DIR)
    p.mkdir(parents=True, exist_ok=True)
    log_file = p / LEGACY_LOG_FILE
    if not log_file.exists():
        with open(log_file, "w", newline="") as f:
            csv.writer(f).writerow(LEGACY_FIELDS)
    return log_file


def append_legacy_module(
    module_label: str,
    hw_addr: int,
    cells: list[float],
    module_v: float,
    temp1: float,
    temp2: float,
    serial_num: str = "",
) -> None:
    """Append one module reading to the legacy CSV for SummaryTab compatibility."""
    log_file = ensure_legacy_log()
    valid = [v for v in cells if _valid(v)]
    spread = (max(valid) - min(valid)) * 1000 if valid else 0.0
    avg = sum(valid) / len(valid) if valid else 0.0

    row = [
        datetime.datetime.now().isoformat(timespec="seconds"),
        module_label,
        serial_num,
        hw_addr,
        *[_fmt(v) for v in cells],
        _fmt(module_v, 4),
        _fmt(temp1, 1),
        _fmt(temp2, 1),
        f"{spread:.1f}",
        _fmt(avg),
    ]
    with open(log_file, "a", newline="") as f:
        csv.writer(f).writerow(row)
