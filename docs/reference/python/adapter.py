"""
can_reader/adapter.py — CAN adapter abstraction layer.

Wraps python-can to support multiple adapter types with a single
connection interface. Auto-detects available ports on the current OS.

Supported adapters:
  socketcan  — CANable (candlelight fw), native Linux SocketCAN
  slcan      — CANable (stock fw), ESP32-CAN, any LAWICEL serial device
  pcan       — PEAK-System PCAN-USB
  gs_usb     — CANable candlelight via gs_usb driver (cross-platform)
  elm327     — OBDLink MX+ / ELM327 serial-to-CAN bridge (read-only)

macOS note: socketcan not supported on macOS. Use slcan, pcan, or gs_usb.
"""

from __future__ import annotations

import platform
import re
import sys
import time
import threading
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Optional

import can
import serial.tools.list_ports

from config import CAN_BITRATE


class AdapterType(str, Enum):
    SOCKETCAN = "socketcan"
    SLCAN     = "slcan"
    PCAN      = "pcan"
    GS_USB    = "gs_usb"
    ELM327    = "elm327"
    VIRTUAL   = "virtual"    # for offline dev / replay


@dataclass
class AdapterConfig:
    interface: AdapterType = AdapterType.SLCAN
    channel: str = ""                    # port or interface name
    bitrate: int = CAN_BITRATE
    tty_baudrate: int = 115200           # serial baud for slcan / elm327
    receive_own_messages: bool = False


# ── Port auto-detection ───────────────────────────────────────────────────────

def _is_linux() -> bool:
    return sys.platform.startswith("linux")

def _is_macos() -> bool:
    return sys.platform == "darwin"

def _is_windows() -> bool:
    return sys.platform == "win32"


def detect_socketcan_interfaces() -> list[str]:
    """Return available SocketCAN interface names (Linux only)."""
    if not _is_linux():
        return []
    import glob
    nets = glob.glob("/sys/class/net/can*")
    return [p.split("/")[-1] for p in nets]


def detect_serial_ports() -> list[dict]:
    """
    Return list of dicts describing serial ports likely to be CAN adapters.
    Each dict: {device, description, vid, pid, likely_adapter_type}
    """
    results = []
    for p in serial.tools.list_ports.comports():
        entry = {
            "device": p.device,
            "description": p.description or "",
            "vid": p.vid,
            "pid": p.pid,
            "likely_type": AdapterType.SLCAN,  # default
        }
        desc_lower = (p.description or "").lower()
        # OBDLink / ELM327
        if "obdlink" in desc_lower or "elm327" in desc_lower or "stn" in desc_lower:
            entry["likely_type"] = AdapterType.ELM327
        # Known CAN adapter descriptions
        elif any(x in desc_lower for x in ["canable", "can", "lawicel", "kvaser"]):
            entry["likely_type"] = AdapterType.SLCAN
        results.append(entry)

    # macOS — filter for typical USB-serial adapters
    if _is_macos():
        results = [r for r in results if any(
            pat in r["device"] for pat in
            ["/dev/cu.usbmodem", "/dev/cu.usbserial", "/dev/cu.SLAB",
             "/dev/cu.wchusbserial", "/dev/cu.OBDLink"]
        )]

    return results


def get_available_adapters() -> list[AdapterConfig]:
    """
    Return a list of AdapterConfigs for all detected interfaces.
    Used to populate the GUI connection panel dropdown.
    """
    configs: list[AdapterConfig] = []

    # SocketCAN interfaces (Linux)
    for iface in detect_socketcan_interfaces():
        configs.append(AdapterConfig(
            interface=AdapterType.SOCKETCAN,
            channel=iface,
            bitrate=CAN_BITRATE,
        ))

    # Serial ports
    for port in detect_serial_ports():
        configs.append(AdapterConfig(
            interface=port["likely_type"],
            channel=port["device"],
            bitrate=CAN_BITRATE,
            tty_baudrate=115200,
        ))

    # Always offer virtual bus for offline dev
    configs.append(AdapterConfig(
        interface=AdapterType.VIRTUAL,
        channel="test",
    ))

    return configs


# ── Bus factory ───────────────────────────────────────────────────────────────

class CANConnectionError(Exception):
    pass


def create_bus(config: AdapterConfig) -> can.BusABC:
    """
    Create and return a python-can Bus for the given config.
    Raises CANConnectionError with a human-readable message on failure.
    """
    try:
        if config.interface == AdapterType.SOCKETCAN:
            if not _is_linux():
                raise CANConnectionError(
                    "SocketCAN is only available on Linux. "
                    "Use slcan or pcan on macOS/Windows."
                )
            return can.Bus(
                interface="socketcan",
                channel=config.channel,
                bitrate=config.bitrate,
            )

        elif config.interface == AdapterType.SLCAN:
            return can.Bus(
                interface="slcan",
                channel=config.channel,
                tty_baudrate=config.tty_baudrate,
                bitrate=config.bitrate,
            )

        elif config.interface == AdapterType.PCAN:
            return can.Bus(
                interface="pcan",
                channel=config.channel or "PCAN_USBBUS1",
                bitrate=config.bitrate,
            )

        elif config.interface == AdapterType.GS_USB:
            return can.Bus(
                interface="gs_usb",
                channel=config.channel or 0,
                bitrate=config.bitrate,
            )

        elif config.interface == AdapterType.ELM327:
            # ELM327 needs its own serial handler — not native python-can
            return ELM327Bus(config)

        elif config.interface == AdapterType.VIRTUAL:
            return can.Bus(
                interface="virtual",
                channel=config.channel or "test",
                receive_own_messages=config.receive_own_messages,
            )

        else:
            raise CANConnectionError(f"Unknown adapter type: {config.interface}")

    except CANConnectionError:
        raise
    except can.CanInterfaceNotImplementedError as e:
        raise CANConnectionError(
            f"CAN interface '{config.interface}' not available: {e}\n"
            "Check that the required driver/library is installed."
        ) from e
    except Exception as e:
        raise CANConnectionError(
            f"Failed to open {config.interface} on {config.channel}: {e}"
        ) from e


# ── ELM327 / OBDLink MX+ bus adapter ─────────────────────────────────────────

class ELM327Bus(can.BusABC):
    """
    Minimal python-can compatible bus for ELM327/STN adapters in ATMA mode.

    The OBDLink MX+ (STN2120) can handle Tesla's ~1000 frame/sec bus.
    Cheap ELM327 clones cannot — they will drop frames.

    This adapter is READ-ONLY. UDS/sending requires a real CAN adapter.

    AT command sequence:
        ATZ    — reset
        ATE0   — echo off
        ATL0   — linefeeds off
        ATH1   — show headers
        ATSP6  — ISO 15765-4 CAN 500k (but we want raw CAN, not OBD)
        ATCAF0 — CAN auto-formatting off
        ATCSM1 — CAN silent monitoring on
        ATMA   — monitor all frames
    """

    # Regex: "6F2 18 6D C6 A3 C1 66 64 1A" or "6F218..."
    _FRAME_RE = re.compile(
        r"([0-9A-Fa-f]{3,8})\s+([0-9A-Fa-f]{2}(?:\s+[0-9A-Fa-f]{2}){0,7})"
    )

    def __init__(self, config: AdapterConfig):
        super().__init__(channel=config.channel, bitrate=config.bitrate)
        self._config = config
        self._ser: Optional[serial.Serial] = None
        self._recv_queue: list[can.Message] = []
        self._lock = threading.Lock()
        self._frame_count = 0
        self._frame_count_t = time.monotonic()
        self._frame_rate = 0.0
        self._open()

    def _open(self):
        import serial as _serial
        self._ser = _serial.Serial(
            port=self._config.channel,
            baudrate=self._config.tty_baudrate,
            timeout=0.1,
        )
        time.sleep(0.2)
        self._ser.reset_input_buffer()

        # Send AT init sequence
        for cmd in ["ATZ", "ATE0", "ATL0", "ATH1", "ATCAF0", "ATCSM1", "ATMA"]:
            self._ser.write((cmd + "\r").encode())
            time.sleep(0.1 if cmd == "ATZ" else 0.05)
            self._ser.read(self._ser.in_waiting or 0)

        # Start background reader thread
        self._running = True
        self._thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._thread.start()

    def _reader_loop(self):
        buf = ""
        while self._running:
            try:
                chunk = self._ser.read(256).decode("ascii", errors="ignore")
                if not chunk:
                    continue
                buf += chunk
                lines = buf.split("\r")
                buf = lines[-1]
                for line in lines[:-1]:
                    msg = self._parse_line(line.strip())
                    if msg:
                        with self._lock:
                            self._recv_queue.append(msg)
                            # Frame rate tracking
                            self._frame_count += 1
                            now = time.monotonic()
                            if now - self._frame_count_t >= 1.0:
                                self._frame_rate = self._frame_count / (now - self._frame_count_t)
                                self._frame_count = 0
                                self._frame_count_t = now
            except Exception:
                pass

    def _parse_line(self, line: str) -> Optional[can.Message]:
        m = self._FRAME_RE.match(line)
        if not m:
            return None
        try:
            arb_id = int(m.group(1), 16)
            data = bytes.fromhex(m.group(2).replace(" ", ""))
            return can.Message(
                arbitration_id=arb_id,
                data=data,
                is_extended_id=arb_id > 0x7FF,
                timestamp=time.time(),
            )
        except (ValueError, Exception):
            return None

    def recv(self, timeout: Optional[float] = None) -> Optional[can.Message]:
        deadline = time.monotonic() + (timeout or 0.1)
        while time.monotonic() < deadline:
            with self._lock:
                if self._recv_queue:
                    return self._recv_queue.pop(0)
            time.sleep(0.001)
        return None

    def send(self, msg: can.Message, timeout: Optional[float] = None) -> None:
        raise can.CanOperationError(
            "ELM327 adapter is read-only. "
            "Use a CANable or PCAN adapter for sending (UDS)."
        )

    def shutdown(self) -> None:
        self._running = False
        if self._ser and self._ser.is_open:
            try:
                self._ser.write(b"ATZ\r")
            except Exception:
                pass
            self._ser.close()

    @property
    def frame_rate(self) -> float:
        return self._frame_rate

    @property
    def is_read_only(self) -> bool:
        return True
