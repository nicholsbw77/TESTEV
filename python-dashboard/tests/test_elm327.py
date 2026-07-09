"""OBDLink MX+ (ELM327/STN serial) source tests — runnable with plain
`python3 tests/test_elm327.py`. Uses a scripted fake serial port, so neither
pyserial nor hardware is needed.
"""

import os
import queue
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tesladash.sources import Elm327SerialSource, OBDLINK_DEFAULT_IDS  # noqa: E402


class FakeSerial:
    """Answers '>' to every command; after ATMA, streams monitor lines."""

    def __init__(self, monitor_payload: bytes):
        self.written: list[bytes] = []
        self.rx = b""
        self.monitor_payload = monitor_payload
        self.closed = False

    def write(self, data: bytes):
        self.written.append(data)
        cmd = data.strip()
        if cmd == b"ATMA":
            self.rx += self.monitor_payload
            self.monitor_payload = b""       # stream once
        elif cmd:
            self.rx += b"OK\r>"

    def read(self, n: int) -> bytes:
        out, self.rx = self.rx[:n], self.rx[n:]
        if not out:
            time.sleep(0.01)                 # emulate serial timeout
        return out

    def reset_input_buffer(self):
        self.rx = b""

    def close(self):
        self.closed = True


def test_parse_monitor_line():
    p = Elm327SerialSource.parse_monitor_line
    # 0x132 pack frame: 350.00 V, -123.4 A
    assert p(b"13288B8FB2E00000000") == (0x132, bytes.fromhex("88B8FB2E00000000"))
    assert p(b"6F2" + b"00" * 8) == (0x6F2, bytes(8))
    assert p(b"33212340000") == (0x332, bytes.fromhex("12340000"))  # short DLC
    for noise in (b"", b">", b"OK", b"SEARCHING...", b"BUFFER FULL",
                  b"13288B8FB2E0000000",   # odd hex count
                  b"NODATA"):
        assert p(noise) is None, noise


def test_full_source_against_fake_serial():
    monitor = (b"13288B8FB2E00000000\r"
               b"BUFFER FULL\r"            # must trigger an ATMA restart
               b"39204000000000BAA0000\r"  # garbage-length line → ignored
               b"3921E1400000000000\r")    # 0x392-ish, wrong dlc parse ok
    q: queue.Queue = queue.Queue()
    fake = FakeSerial(monitor)
    src = Elm327SerialSource(q, port="FAKE", ids=(0x132, 0x392), _serial=fake)
    src.start()
    deadline = time.time() + 5
    frames = []
    while time.time() < deadline and len(frames) < 2:
        try:
            frames.append(q.get(timeout=0.2))
        except queue.Empty:
            pass
    src.stop()
    src.join(timeout=3)

    sent = b"".join(fake.written)
    # verified init sequence from the Flutter app, in order
    for cmd in (b"ATZ", b"ATE0", b"ATH1", b"ATS0", b"ATSP6", b"ATCAF0",
                b"ATCSM1", b"STFCP", b"STFAP 132,7FF", b"STFAP 392,7FF"):
        assert cmd + b"\r" in sent, f"missing init cmd {cmd}"
    assert sent.count(b"ATMA\r") >= 2, "BUFFER FULL must restart monitor mode"

    ids = [f.id for f in frames]
    assert 0x132 in ids, ids
    f132 = frames[ids.index(0x132)]
    assert f132.data[:4] == bytes.fromhex("88B8FB2E")
    assert fake.closed


def test_default_filter_ids_match_flutter_app():
    assert OBDLINK_DEFAULT_IDS == (0x132, 0x332, 0x392, 0x6F2, 0x7E2)


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
