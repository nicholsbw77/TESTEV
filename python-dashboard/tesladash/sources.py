"""CAN frame sources. Each runs on its own thread and pushes CanFrame objects
into a queue that the GUI thread drains (see app.py) — the dashboard never
touches Qt from these threads.

All sources are LISTEN-ONLY: nothing here ever transmits onto the vehicle bus
(the SLCAN open/close commands go to the adapter, not the car).
"""

import math
import queue
import socket
import threading
import time

from .frames import CanFrame


class Source(threading.Thread):
    """Base class: run() produces frames via self.emit()."""

    description = "abstract"

    def __init__(self, out_queue: queue.Queue):
        super().__init__(daemon=True)
        self.q = out_queue
        self._stop_evt = threading.Event()
        self.error: str | None = None
        self.connected = False

    def stop(self) -> None:
        self._stop_evt.set()

    @property
    def stopping(self) -> bool:
        return self._stop_evt.is_set()

    def emit(self, can_id: int, data: bytes) -> None:
        try:
            self.q.put_nowait(CanFrame(can_id, data))
        except queue.Full:
            pass  # GUI is behind; dropping frames beats unbounded memory


# ── SocketCAN (Linux: CAN HAT / USB candleLight / slcand) ─────────────────


class SocketCanSource(Source):
    def __init__(self, out_queue, channel: str = "can0"):
        super().__init__(out_queue)
        self.channel = channel
        self.description = f"socketcan {channel} (listen-only)"

    def run(self) -> None:
        try:
            import can  # python-can, imported lazily so it stays optional
        except ImportError:
            self.error = "python-can not installed (pip install python-can)"
            return
        try:
            bus = can.Bus(channel=self.channel, interface="socketcan")
        except Exception as exc:
            self.error = f"cannot open {self.channel}: {exc}"
            return
        self.connected = True
        try:
            while not self.stopping:
                msg = bus.recv(timeout=0.5)
                if msg is not None and not msg.is_error_frame:
                    self.emit(msg.arbitration_id, bytes(msg.data))
        except Exception as exc:
            self.error = str(exc)
        finally:
            self.connected = False
            bus.shutdown()


# ── SLCAN over TCP (MeatPi WiCAN) — port of lib/can/slcan_adapter.dart ────


class SlcanTcpSource(Source):
    def __init__(self, out_queue, host: str = "192.168.50.158", port: int = 3333):
        super().__init__(out_queue)
        self.host, self.port = host, port
        self.description = f"WiCAN slcan tcp://{host}:{port}"

    def run(self) -> None:
        try:
            sock = socket.create_connection((self.host, self.port), timeout=5)
        except OSError as exc:
            self.error = f"cannot connect to {self.host}:{self.port}: {exc}"
            return
        sock.settimeout(1.0)
        try:
            # SLCAN init: close, 500k, open (same sequence as the Flutter app)
            for cmd in (b"\r", b"C\r", b"S6\r", b"O\r"):
                sock.sendall(cmd)
                time.sleep(0.1)
            self.connected = True
            buf = b""
            while not self.stopping:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                while b"\r" in buf:
                    line, buf = buf.split(b"\r", 1)
                    self._parse_line(line.strip())
        except OSError as exc:
            self.error = str(exc)
        finally:
            self.connected = False
            try:
                sock.sendall(b"C\r")
                sock.close()
            except OSError:
                pass

    def _parse_line(self, line: bytes) -> None:
        # t<id:3><dlc:1><data...> standard / T<id:8>... extended
        try:
            if line[:1] == b"t":
                can_id = int(line[1:4], 16)
                dlc = int(line[4:5])
                data = bytes.fromhex(line[5:5 + dlc * 2].decode())
                self.emit(can_id, data)
            elif line[:1] == b"T":
                can_id = int(line[1:9], 16)
                dlc = int(line[9:10])
                data = bytes.fromhex(line[10:10 + dlc * 2].decode())
                self.emit(can_id, data)
        except (ValueError, IndexError):
            pass  # noise / partial line


# ── ELM327/STN over a serial port (OBDLink MX+ via Bluetooth SPP) ─────────
# On Windows 11 the paired MX+ shows up as an outgoing "Standard Serial over
# Bluetooth link" COM port; on Linux it's /dev/rfcomm0. Init + STN hardware
# filters are the exact sequence lib/can/elm327_adapter.dart verified on this
# adapter and car. ATCSM1 = silent monitoring: the adapter never ACKs a frame.

#: CAN IDs verified present on the vehicle OBD bus (Flutter app's filter set).
OBDLINK_DEFAULT_IDS = (0x132, 0x332, 0x392, 0x6F2, 0x7E2)


class Elm327SerialSource(Source):
    def __init__(self, out_queue, port: str = "auto", baud: int = 115200,
                 ids=OBDLINK_DEFAULT_IDS, _serial=None):
        super().__init__(out_queue)
        self.port, self.baud = port, baud
        self.ids = tuple(ids) if ids else OBDLINK_DEFAULT_IDS
        self._injected = _serial          # test hook: fake serial object
        self.description = f"OBDLink {port}"

    # — connection —

    def _open(self):
        if self._injected is not None:
            return self._injected
        try:
            import serial  # pyserial, lazy so it stays optional
        except ImportError:
            self.error = "pyserial not installed (pip install pyserial)"
            return None
        if self.port and self.port != "auto":
            try:
                return serial.Serial(self.port, self.baud, timeout=1)
            except Exception as exc:
                self.error = f"cannot open {self.port}: {exc}"
                return None
        ser = self._autodetect(serial)
        if ser is None and not self.error:
            self.error = ("no OBDLink found — pass --serial-port COMx "
                          "(see Bluetooth COM Ports in Windows settings)")
        return ser

    def _autodetect(self, serial):
        """Probe COM ports with ATI, prefer ones that look like an OBDLink.
        Opening a Bluetooth COM port is what triggers the BT connection, so
        each probe can take a few seconds."""
        try:
            from serial.tools import list_ports
            ports = list(list_ports.comports())
        except Exception as exc:
            self.error = f"cannot enumerate serial ports: {exc}"
            return None
        ports.sort(key=lambda p: ("obdlink" not in (p.description or "").lower(),
                                  "bluetooth" not in (p.description or "").lower(),
                                  p.device))
        for p in ports:
            if self.stopping:
                return None
            try:
                ser = serial.Serial(p.device, self.baud, timeout=2, write_timeout=3)
            except Exception:
                continue
            try:
                ser.reset_input_buffer()
                ser.write(b"\rATI\r")
                time.sleep(0.6)
                resp = ser.read(256).upper()
                if b"ELM" in resp or b"STN" in resp or b"OBDLINK" in resp:
                    self.description = f"OBDLink {p.device}"
                    return ser
            except Exception:
                pass
            try:
                ser.close()
            except Exception:
                pass
        return None

    # — protocol —

    def _cmd(self, ser, cmd: bytes, timeout: float = 2.0) -> bytes:
        """Send one AT/ST command, collect the reply up to the '>' prompt."""
        ser.reset_input_buffer()
        ser.write(cmd + b"\r")
        resp, deadline = b"", time.time() + timeout
        while time.time() < deadline:
            chunk = ser.read(64)
            if chunk:
                resp += chunk
                if b">" in resp:
                    break
        return resp

    def _init_adapter(self, ser) -> None:
        self._cmd(ser, b"ATZ", timeout=3.0)   # reset
        for cmd in (b"ATE0",     # echo off
                    b"ATL0",     # linefeeds off
                    b"ATH1",     # headers on (we need the CAN ID)
                    b"ATS0",     # spaces off (compact hex)
                    b"ATSP6",    # ISO 15765-4 CAN 500k
                    b"ATCAF0",   # raw frames, no ISO-TP formatting
                    b"ATCSM1",   # silent monitoring — never ACK the bus
                    b"STFCP"):   # clear STN pass filters
            self._cmd(ser, cmd)
        for can_id in self.ids:  # additive STN pass list
            self._cmd(ser, b"STFAP %03X,7FF" % can_id)

    def run(self) -> None:
        ser = self._open()
        if ser is None:
            return
        try:
            self._init_adapter(ser)
            ser.write(b"ATMA\r")             # monitor-all (through the filters)
            self.connected = True
            buf = b""
            while not self.stopping:
                chunk = ser.read(256)
                if not chunk:
                    continue
                buf += chunk
                # ELM output delimits lines with \r; '>' means monitor stopped
                *lines, buf = buf.replace(b">", b"\r>").split(b"\r")
                restart = False
                for line in lines:
                    line = line.strip()
                    if not line:
                        continue
                    if (line.startswith(b">") or b"BUFFER FULL" in line
                            or b"STOPPED" in line or b"CAN ERROR" in line):
                        restart = True
                        continue
                    frame = self.parse_monitor_line(line)
                    if frame:
                        self.emit(*frame)
                if restart and not self.stopping:
                    ser.write(b"ATMA\r")
                if len(buf) > 4096:          # runaway garbage guard
                    buf = b""
        except Exception as exc:
            self.error = str(exc)
        finally:
            self.connected = False
            try:
                ser.write(b"\r")             # leave monitor mode
                time.sleep(0.2)
                ser.close()
            except Exception:
                pass

    @staticmethod
    def parse_monitor_line(line: bytes):
        """ATH1+ATS0 monitor line: 3 hex ID chars + hex data pairs,
        e.g. b'13288B8FB2E00000000' → (0x132, 8 bytes). Returns None on noise."""
        if len(line) < 5 or (len(line) - 3) % 2:
            return None
        try:
            can_id = int(line[:3], 16)
            data = bytes.fromhex(line[3:3 + 16].decode())
        except ValueError:
            return None
        return can_id, data


# ── candump log replay (verification tool) ────────────────────────────────


class CandumpReplaySource(Source):
    """Replays a `candump -L` log file (lines like
    `(1690000000.123456) can0 132#0F2A03E8...`), preserving timing.
    Loops forever so the dashboard can be styled against a real capture.
    """

    def __init__(self, out_queue, path: str, speed: float = 1.0):
        super().__init__(out_queue)
        self.path, self.speed = path, speed
        self.description = f"replay {path}"

    def run(self) -> None:
        try:
            frames = self._load()
        except OSError as exc:
            self.error = str(exc)
            return
        if not frames:
            self.error = "no parsable frames in log"
            return
        self.connected = True
        while not self.stopping:
            t0 = frames[0][0]
            start = time.time()
            for ts, can_id, data in frames:
                if self.stopping:
                    return
                delay = (ts - t0) / self.speed - (time.time() - start)
                if delay > 0:
                    time.sleep(min(delay, 1.0))
                self.emit(can_id, data)

    def _load(self):
        frames = []
        with open(self.path) as f:
            for line in f:
                try:
                    ts_part, _iface, frame_part = line.split(maxsplit=2)
                    ts = float(ts_part.strip("()"))
                    id_part, data_part = frame_part.strip().split("#", 1)
                    can_id = int(id_part, 16)
                    data = bytes.fromhex(data_part.replace(".", "")[:16])
                    frames.append((ts, can_id, data))
                except ValueError:
                    continue
        return frames


# ── Simulator — full desk-test mode, no hardware needed ───────────────────


class SimulatorSource(Source):
    """Emits realistic Model S traffic for every decoder in decoders.py,
    including complete 0x6F2 cell/temp sweeps, so the whole dashboard can be
    exercised (and screenshotted) without a car.
    """

    description = "simulator (no hardware)"

    def run(self) -> None:
        self.connected = True
        t0 = time.time()
        mux = 0
        soc = 78.0
        cells = [3.95 + 0.012 * math.sin(i * 0.7) for i in range(96)]
        while not self.stopping:
            t = time.time() - t0
            # a gentle "driving cycle": accelerate / cruise / regen
            drive = max(-0.35, math.sin(t / 9.0)) * max(0.0, math.sin(t / 23.0) + 0.2)
            speed_mph = max(0.0, 52 + 28 * math.sin(t / 17.0))
            rpm = speed_mph * 105
            current = 320 * drive          # A, discharge positive
            soc = max(5.0, soc - max(0.0, current) * 1.2e-5)
            volts = 350 + (soc - 50) * 0.55 - current * 0.02
            batt_temp = 24 + 6 * (1 - math.exp(-t / 600))

            self.emit(0x132, self._enc_be16(volts / 0.01) +
                      self._enc_be16(int(current / 0.1) & 0xFFFF) + b"\x00" * 4)
            self.emit(0x332, self._enc_be16(soc / 0.01) + b"\x00" * 6)
            # 0x392 mux 01 (kW limits) and mux 04 (current limit, LE)
            self.emit(0x392, bytes([0x01]) + self._enc_be16(310 / 0.01) +
                      b"\x00" + self._enc_be16(60 / 0.01) + b"\x00\x00")
            raw_i = int(1290 / 0.1)
            self.emit(0x392, bytes([0x04, 0, 0, 0, raw_i & 0xFF, raw_i >> 8, 0, 0]))

            # drive unit + thermals + energy (community-DBC layouts)
            self.emit(0x106, self._enc_di_torque1(rpm, pedal=40 * max(0.0, drive)))
            self.emit(0x116, self._enc_di_torque2(speed_mph, gear=4))
            self.emit(0x266, self._enc_du_power(dissipation_w=2500 + 9000 * abs(drive),
                                                mech_kw=volts * current / 1000,
                                                stator_a=abs(current) * 2.4))
            self.emit(0x210, self._enc_dcdc(inlet_c=31 + 9 * (1 - math.exp(-t / 400)),
                                            out_v=13.9, out_a=38))
            self.emit(0x382, self._enc_energy(nominal_full=74.3,
                                              remaining=74.3 * soc / 100))
            self.emit(0x3D2, int(18432_000).to_bytes(4, "little") +
                      int(20120_000).to_bytes(4, "little"))
            self.emit(0x562, int(83452.0 / 0.001).to_bytes(4, "little"))

            # two 0x6F2 mux frames per tick → full 32-frame sweep ≈ 0.8 s
            for _ in range(2):
                self.emit(0x6F2, self._enc_6f2(mux, cells, batt_temp, t))
                mux = (mux + 1) % 32
            time.sleep(0.05)

    # — encoders are exact inverses of the decoders (also used by tests) —

    @staticmethod
    def _enc_be16(value: float) -> bytes:
        return int(round(value)) .to_bytes(2, "big")

    @staticmethod
    def _enc_di_torque1(rpm: float, pedal: float) -> bytes:
        d = bytearray(8)
        d[4:6] = (int(rpm) & 0xFFFF).to_bytes(2, "little")
        d[6] = int(pedal / 0.4) & 0xFF
        return bytes(d)

    @staticmethod
    def _enc_di_torque2(speed_mph: float, gear: int) -> bytes:
        d = bytearray(6)
        raw = int((speed_mph + 25.0) / 0.05) & 0xFFF
        d[1] |= (gear & 0x7) << 4          # bits 12-14
        d[2] = raw & 0xFF                  # bits 16-27
        d[3] |= (raw >> 8) & 0x0F
        return bytes(d)

    @staticmethod
    def _enc_du_power(dissipation_w: float, mech_kw: float, stator_a: float) -> bytes:
        d = bytearray(8)
        d[1] = min(255, int(dissipation_w / 125))
        raw_mech = int(mech_kw / 0.5) & 0x7FF
        d[2] = raw_mech & 0xFF
        d[3] |= (raw_mech >> 8) & 0x07
        raw_st = int(stator_a) & 0x7FF
        d[4] = raw_st & 0xFF
        d[5] |= (raw_st >> 8) & 0x07
        return bytes(d)

    @staticmethod
    def _enc_dcdc(inlet_c: float, out_v: float, out_a: float) -> bytes:
        d = bytearray(7)
        d[2] = int((inlet_c - 40.0) / 0.5) & 0xFF
        d[3] = int(450 / 16)
        d[4] = int(out_a)
        d[5] = int(out_v / 0.1)
        return bytes(d)

    @staticmethod
    def _enc_energy(nominal_full: float, remaining: float) -> bytes:
        raw = (int(nominal_full / 0.1) & 0x3FF)
        raw |= (int(remaining / 0.1) & 0x3FF) << 10
        raw |= (int(remaining / 0.1) & 0x3FF) << 20      # expected ≈ nominal
        raw |= (int(3.2 / 0.1) & 0xFF) << 50             # energy buffer
        return raw.to_bytes(8, "little")

    @staticmethod
    def _enc_6f2(mux: int, cells: list, batt_temp: float, t: float) -> bytes:
        vals = []
        if mux <= 0x17:
            for i in range(4):
                idx = mux * 4 + i
                v = cells[idx] + 0.003 * math.sin(t / 30 + idx)
                vals.append(int(v / 0.000305) & 0x3FFF)
        else:
            for i in range(4):
                idx = (mux - 0x18) * 4 + i
                temp = batt_temp + 1.5 * math.sin(idx * 0.9)
                vals.append(int(temp / 0.0122) & 0x3FFF)
        raw = 0
        for i, v in enumerate(vals):
            raw |= v << (i * 14)
        return bytes([mux]) + raw.to_bytes(7, "little")


def make_source(kind: str, out_queue, **kw) -> Source:
    if kind == "sim":
        return SimulatorSource(out_queue)
    if kind == "socketcan":
        return SocketCanSource(out_queue, channel=kw.get("channel", "can0"))
    if kind == "wican":
        return SlcanTcpSource(out_queue, host=kw.get("host", "192.168.50.158"),
                              port=kw.get("port", 3333))
    if kind == "replay":
        return CandumpReplaySource(out_queue, path=kw["log"], speed=kw.get("speed", 1.0))
    if kind == "obdlink":
        return Elm327SerialSource(out_queue, port=kw.get("serial_port", "auto"),
                                  baud=kw.get("baud", 115200),
                                  ids=kw.get("ids") or OBDLINK_DEFAULT_IDS)
    raise ValueError(f"unknown source: {kind}")
