"""
Tesla BMS Bench Tester — main entry point.

Usage:
    python main.py                    # launch GUI
    python main.py --replay FILE.log  # launch GUI with log file replay
    python main.py --no-gui --replay  # headless replay for testing

Run from the tesla_bench_tester/ directory:
    cd tesla_bench_tester
    python main.py
"""

import sys
import argparse
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description="Tesla BMS Bench Tester")
    ap.add_argument("--replay", metavar="FILE",
                    help="Replay a CAN log file instead of connecting to hardware")
    ap.add_argument("--replay-speed", type=float, default=1.0,
                    help="Replay speed multiplier (default 1.0)")
    ap.add_argument("--no-gui", action="store_true",
                    help="Headless mode (for testing)")
    args = ap.parse_args()

    if args.no_gui:
        _headless(args)
        return

    from PyQt6.QtWidgets import QApplication
    from gui.main_window import MainWindow

    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setApplicationName("Tesla BMS Bench Tester")

    win = MainWindow()

    # If a replay file was given, pre-configure the CAN connection to use it
    if args.replay:
        replay_path = Path(args.replay)
        if not replay_path.exists():
            print(f"Replay file not found: {replay_path}", file=sys.stderr)
            sys.exit(1)
        _setup_replay(win, replay_path, args.replay_speed)

    win.show()
    sys.exit(app.exec())


def _setup_replay(win, path: Path, speed: float):
    """Pre-configure the GUI to connect to a replay virtual bus."""
    from can_reader.adapter import AdapterConfig, AdapterType
    from can_reader.replay import create_replay_bus, parse_log_file

    print(f"Replay mode: {path.name} at {speed}x speed")
    frames = parse_log_file(path)
    if not frames:
        print(f"No frames found in {path}", file=sys.stderr)
        return

    # Connect via virtual adapter — replay bus starts in background
    cfg = AdapterConfig(
        interface=AdapterType.VIRTUAL,
        channel="replay",
        receive_own_messages=False,
    )
    # Start the replayer onto the virtual bus
    from can_reader.replay import BusReplayer
    import can
    write_bus = can.Bus(interface="virtual", channel="replay", receive_own_messages=False)
    replayer = BusReplayer(frames, write_bus, speed=speed, loop=True)
    replayer.start()

    # Trigger the GUI to connect to the read side
    from PyQt6.QtCore import QTimer
    QTimer.singleShot(200, lambda: win._on_can_connect(cfg))


def _headless(args):
    """Headless test mode — connect, receive frames, print summary, exit."""
    from can_reader.replay import create_replay_bus, parse_log_file
    from can_reader.decode import CellFrameBuffer, decode_frame
    from config import CAN_ID_BMS_CELL_BLOCK

    if not args.replay:
        print("--no-gui requires --replay FILE", file=sys.stderr)
        sys.exit(1)

    path = Path(args.replay)
    frames = parse_log_file(path)
    print(f"Loaded {len(frames)} frames from {path.name}")

    buf = CellFrameBuffer()
    snapshot = None

    for ts, arb_id, data in frames:
        if arb_id == CAN_ID_BMS_CELL_BLOCK:
            result = buf.feed(data)
            if result and snapshot is None:
                snapshot = result

    if snapshot:
        cells = snapshot["cells"]
        valid = [v for v in cells if v == v]  # filter NaN
        print(f"\nFirst complete cell sweep:")
        print(f"  Cells: {len(valid)}")
        print(f"  Min:   {min(valid):.4f} V")
        print(f"  Max:   {max(valid):.4f} V")
        print(f"  Delta: {(max(valid)-min(valid))*1000:.1f} mV")
    else:
        print("No complete 0x6F2 sweep found.")


if __name__ == "__main__":
    main()
