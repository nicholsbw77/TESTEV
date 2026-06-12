"""Entry point. Wires source thread → frame queue → decoder → state → UI.

Examples:
    python -m tesladash --source sim                      # desk test, no hardware
    python -m tesladash --source socketcan --channel can0 --bus vehicle --fullscreen
    python -m tesladash --source wican --host 192.168.50.158 --bus vehicle
    python -m tesladash --source replay --log capture.log
    python -m tesladash --list-signals
"""

import argparse
import queue
import sys

from .qt import QtCore, QtGui, QtWidgets, qexec, QT_BINDING
from . import config as cfgmod
from .dashboard import MainWindow
from .decoders import TeslaDecoder
from .signals import SIGNALS
from .sources import make_source
from .state import VehicleState


def parse_args(argv=None):
    ap = argparse.ArgumentParser(
        prog="tesladash",
        description="Customizable CAN dashboard for a 2013 Tesla Model S (listen-only).")
    ap.add_argument("--source", choices=("sim", "socketcan", "wican", "replay"),
                    default="sim", help="frame source (default: sim)")
    ap.add_argument("--channel", default="can0", help="socketcan channel")
    ap.add_argument("--host", default="192.168.50.158", help="WiCAN host")
    ap.add_argument("--port", type=int, default=3333, help="WiCAN TCP port")
    ap.add_argument("--log", default="", help="candump -L file for --source replay")
    ap.add_argument("--speed", type=float, default=1.0, help="replay speed factor")
    ap.add_argument("--bus", choices=("vehicle", "bms"), default="vehicle",
                    help="which bus the adapter is on: 'vehicle' = diagnostic "
                         "connector (default), 'bms' = pack-internal bus")
    ap.add_argument("--config", default=cfgmod.DEFAULT_PATH,
                    help="layout JSON path (default: %(default)s)")
    ap.add_argument("--fullscreen", action="store_true", help="kiosk mode for in-car LCD")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="font scale factor for small/far screens")
    ap.add_argument("--list-signals", action="store_true",
                    help="print the signal catalog and exit")
    return ap.parse_args(argv)


def list_signals():
    width = max(len(n) for n in SIGNALS)
    for name, s in sorted(SIGNALS.items()):
        mark = "✓" if s.verified else "⚠"
        print(f"{mark} {name:<{width}}  {s.label} [{s.unit}]  — {s.source}")
    print("\n✓ = decode verified against this car's captures, ⚠ = community decode")


def main(argv=None) -> int:
    args = parse_args(argv)
    if args.list_signals:
        list_signals()
        return 0
    if args.source == "replay" and not args.log:
        print("--source replay requires --log <candump file>", file=sys.stderr)
        return 2

    app = QtWidgets.QApplication(sys.argv[:1])
    if args.scale != 1.0:
        f = app.font()
        f.setPointSizeF(f.pointSizeF() * args.scale)
        app.setFont(f)

    state = VehicleState()
    decoder = TeslaDecoder(state, vehicle_bus=(args.bus == "vehicle"))
    cfg = cfgmod.load(args.config)

    frame_q: queue.Queue = queue.Queue(maxsize=20000)
    source = make_source(args.source, frame_q, channel=args.channel,
                         host=args.host, port=args.port,
                         log=args.log, speed=args.speed)
    state.source_desc = source.description
    source.start()

    win = MainWindow(state, cfg, args.config)
    win.resize(1280, 800)
    if args.fullscreen:
        win.showFullScreen()
    else:
        win.show()

    def pump():
        """Drain queued frames (GUI thread), then refresh tiles at ~10 Hz."""
        drained = 0
        try:
            while drained < 2000:           # bound per tick to stay responsive
                frame = frame_q.get_nowait()
                decoder.feed(frame)
                drained += 1
        except queue.Empty:
            pass
        state.connected = source.connected
        if source.error and not state.source_desc.endswith(source.error):
            state.source_desc = f"{source.description} — {source.error}"
        state.recompute_derived(cfg.pack_new_kwh)
        state.sample_history()
        win.tick()

    timer = QtCore.QTimer()
    timer.timeout.connect(pump)
    timer.start(100)

    rc = qexec(app)
    source.stop()
    source.join(timeout=2)
    return rc


if __name__ == "__main__":
    sys.exit(main())
