"""Dashboard tiles. Every tile binds to a signal name from signals.SIGNALS and
repaints from VehicleState on the GUI tick. Painted with plain QPainter so the
whole UI runs fine without OpenGL (relevant on older in-car hardware).
"""

import math

from .qt import QtCore, QtGui, QtWidgets
from .signals import SIGNALS, SignalSpec
from .state import VehicleState, is_num

Qt = QtCore.Qt

# ── theme ──────────────────────────────────────────────────────────────────

BG = "#0b0d10"          # window background
TILE_BG = "#15181d"     # tile background
TILE_EDIT = "#1d2330"   # tile background in edit mode
FG = "#e8eaed"          # primary value text
DIM = "#8b949e"         # labels / stale values
ACCENT = "#34c3ff"      # gauge fill
GOOD = "#33d17a"
WARN = "#ffb02e"
ALERT = "#ff5d52"
TRACK = "#272c33"       # gauge background track

STALE_AFTER_S = 5.0     # dim a value if the signal stops updating


def _color(name: str) -> QtGui.QColor:
    return QtGui.QColor(name)


def lerp_color(c1: str, c2: str, f: float) -> QtGui.QColor:
    f = max(0.0, min(1.0, f))
    a, b = _color(c1), _color(c2)
    return QtGui.QColor(int(a.red() + (b.red() - a.red()) * f),
                        int(a.green() + (b.green() - a.green()) * f),
                        int(a.blue() + (b.blue() - a.blue()) * f))


def display(spec: SignalSpec, value: float, metric: bool) -> tuple[float, str]:
    """Apply unit conversion for metric mode. Returns (value, unit)."""
    if metric and spec.name == "vehicle_speed":
        return value * 1.60934, "km/h"
    if metric and spec.name == "odometer":
        return value * 1.60934, "km"
    return value, spec.unit


def value_color(spec: SignalSpec, v: float) -> str:
    if spec.warn_hi is not None and v >= spec.warn_hi:
        return ALERT if v >= spec.warn_hi * 1.1 else WARN
    if spec.warn_lo is not None and v <= spec.warn_lo:
        return WARN
    return FG


# ── tile base ──────────────────────────────────────────────────────────────


class Tile(QtWidgets.QFrame):
    remove_requested = None  # set by dashboard: callable(tile)

    def __init__(self, cfg, parent=None):
        super().__init__(parent)
        self.cfg = cfg
        self.spec = SIGNALS.get(cfg.signal)
        self.index = 0          # position in layout, set on rebuild
        self.edit_mode = False
        self._press_pos = None
        self.setMinimumSize(190, 150)
        self.setSizePolicy(QtWidgets.QSizePolicy.Expanding,
                           QtWidgets.QSizePolicy.Expanding)
        self._apply_style()

        self.close_btn = QtWidgets.QToolButton(self)
        self.close_btn.setText("✕")
        self.close_btn.setStyleSheet(
            f"QToolButton {{ color: {ALERT}; background: transparent;"
            " border: none; font-size: 14px; }")
        self.close_btn.clicked.connect(self._request_remove)
        self.close_btn.hide()

    # — appearance —

    def _apply_style(self):
        bg = TILE_EDIT if self.edit_mode else TILE_BG
        border = f"1px dashed {DIM}" if self.edit_mode else "1px solid #20242b"
        self.setStyleSheet(
            f"Tile {{ background: {bg}; border: {border}; border-radius: 10px; }}")

    def set_edit_mode(self, on: bool):
        self.edit_mode = on
        self.close_btn.setVisible(on)
        self._apply_style()
        self.update()

    def resizeEvent(self, ev):
        self.close_btn.move(self.width() - 26, 6)
        super().resizeEvent(ev)

    def title_text(self) -> str:
        if self.cfg.title:
            return self.cfg.title
        return self.spec.label if self.spec else self.cfg.type

    def lo_hi(self) -> tuple[float, float]:
        lo = self.cfg.lo if self.cfg.lo is not None else (self.spec.lo if self.spec else 0)
        hi = self.cfg.hi if self.cfg.hi is not None else (self.spec.hi if self.spec else 100)
        return float(lo), float(hi)

    # — data —

    def refresh(self, state: VehicleState, metric: bool):
        self.state = state
        self.metric = metric
        self.update()

    def current(self, state) -> tuple[float, str, str]:
        """(value, text, color) for self's signal, handling stale/missing."""
        spec = self.spec
        v = state.get(spec.name) if spec else None
        if spec and spec.text:
            txt = str(v) if v is not None else "—"
            return float("nan"), txt, FG if state.age(spec.name) < STALE_AFTER_S else DIM
        if not is_num(v):
            return float("nan"), "—", DIM
        val, _unit = display(spec, float(v), getattr(self, "metric", False))
        txt = f"{val:.{spec.decimals}f}"
        col = value_color(spec, float(v))
        if state.age(spec.name) > STALE_AFTER_S:
            col = DIM
        return val, txt, col

    def unit_text(self) -> str:
        if not self.spec:
            return ""
        return display(self.spec, 0.0, getattr(self, "metric", False))[1]

    # — edit-mode drag & remove —

    def _request_remove(self):
        if callable(self.remove_requested):
            self.remove_requested(self)

    def mousePressEvent(self, ev):
        if self.edit_mode and ev.button() == Qt.LeftButton:
            self._press_pos = ev.pos()
        super().mousePressEvent(ev)

    def mouseMoveEvent(self, ev):
        if (self.edit_mode and self._press_pos is not None
                and (ev.pos() - self._press_pos).manhattanLength()
                > QtWidgets.QApplication.startDragDistance()):
            drag = QtGui.QDrag(self)
            mime = QtCore.QMimeData()
            mime.setData("application/x-tesladash-tile", str(self.index).encode())
            drag.setMimeData(mime)
            drag.setPixmap(self.grab().scaledToWidth(140))
            fn = getattr(drag, "exec", None) or drag.exec_
            fn(Qt.MoveAction)
            self._press_pos = None
        super().mouseMoveEvent(ev)

    # — painting helpers —

    def _painter(self) -> QtGui.QPainter:
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        return p

    def _draw_title(self, p: QtGui.QPainter):
        p.setPen(_color(DIM))
        f = self.font()
        f.setPointSizeF(max(7.0, self.font().pointSizeF() * 0.85))
        f.setLetterSpacing(QtGui.QFont.PercentageSpacing, 108)
        p.setFont(f)
        p.drawText(QtCore.QRectF(12, 6, self.width() - 40, 20),
                   Qt.AlignLeft | Qt.AlignVCenter, self.title_text().upper())


# ── numeric tile ───────────────────────────────────────────────────────────


class NumberTile(Tile):
    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        _v, txt, col = self.current(self.state)
        rect = QtCore.QRectF(0, 18, self.width(), self.height() - 44)
        f = self.font()
        f.setPointSizeF(self.font().pointSizeF() * (2.6 if len(txt) < 8 else 2.0))
        f.setBold(True)
        p.setFont(f)
        p.setPen(_color(col))
        p.drawText(rect, Qt.AlignCenter, txt)
        f2 = self.font()
        f2.setPointSizeF(self.font().pointSizeF() * 1.0)
        p.setFont(f2)
        p.setPen(_color(DIM))
        p.drawText(QtCore.QRectF(0, self.height() - 30, self.width(), 22),
                   Qt.AlignCenter, self.unit_text())
        p.end()


# ── arc gauge ──────────────────────────────────────────────────────────────


class GaugeTile(Tile):
    SPAN_DEG = 270

    def __init__(self, cfg, parent=None):
        super().__init__(cfg, parent)
        self.setMinimumSize(210, 190)

    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)

        lo, hi = self.lo_hi()
        raw = self.state.num(self.spec.name) if self.spec else float("nan")
        _v, txt, col = self.current(self.state)
        frac = 0.0
        if is_num(raw) and hi > lo:
            frac = max(0.0, min(1.0, (raw - lo) / (hi - lo)))

        side = min(self.width() - 24, self.height() - 34)
        r = QtCore.QRectF((self.width() - side) / 2,
                          (self.height() - side) / 2 + 8, side, side)
        thickness = max(8.0, side * 0.075)
        r = r.adjusted(thickness, thickness, -thickness, -thickness)

        start = 225 * 16   # Qt: 1/16°, 0 = 3 o'clock, CCW positive
        pen = QtGui.QPen(_color(TRACK), thickness, Qt.SolidLine, Qt.RoundCap)
        p.setPen(pen)
        p.drawArc(r, start, -self.SPAN_DEG * 16)
        if frac > 0:
            arc_col = ACCENT if col == FG or col == DIM else col
            pen.setColor(_color(arc_col))
            p.setPen(pen)
            p.drawArc(r, start, int(-self.SPAN_DEG * 16 * frac))

        f = self.font()
        f.setPointSizeF(self.font().pointSizeF() * (2.4 if len(txt) < 7 else 1.8))
        f.setBold(True)
        p.setFont(f)
        p.setPen(_color(col))
        p.drawText(r, Qt.AlignCenter, txt)
        f2 = self.font()
        p.setFont(f2)
        p.setPen(_color(DIM))
        p.drawText(r.adjusted(0, side * 0.28, 0, 0), Qt.AlignCenter, self.unit_text())
        # lo/hi labels at arc ends
        p.drawText(QtCore.QRectF(r.left() - 6, r.bottom() - 14, r.width() * 0.4, 16),
                   Qt.AlignLeft, f"{lo:g}")
        p.drawText(QtCore.QRectF(r.left() + r.width() * 0.6 + 6, r.bottom() - 14,
                                 r.width() * 0.4, 16), Qt.AlignRight, f"{hi:g}")
        p.end()


# ── horizontal bar ─────────────────────────────────────────────────────────


class BarTile(Tile):
    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        lo, hi = self.lo_hi()
        raw = self.state.num(self.spec.name) if self.spec else float("nan")
        _v, txt, col = self.current(self.state)

        f = self.font()
        f.setPointSizeF(self.font().pointSizeF() * 1.9)
        f.setBold(True)
        p.setFont(f)
        p.setPen(_color(col))
        p.drawText(QtCore.QRectF(12, 22, self.width() - 24, 36),
                   Qt.AlignLeft | Qt.AlignVCenter, f"{txt} {self.unit_text()}")

        track = QtCore.QRectF(12, self.height() - 42, self.width() - 24, 18)
        p.setPen(Qt.NoPen)
        p.setBrush(_color(TRACK))
        p.drawRoundedRect(track, 6, 6)
        if is_num(raw) and hi > lo:
            frac = max(0.0, min(1.0, (raw - lo) / (hi - lo)))
            fill = QtCore.QRectF(track)
            fill.setWidth(max(8.0, track.width() * frac))
            p.setBrush(_color(ACCENT if col in (FG, DIM) else col))
            p.drawRoundedRect(fill, 6, 6)
        # warn tick
        if self.spec and self.spec.warn_hi is not None and hi > lo:
            wx = track.left() + track.width() * max(
                0.0, min(1.0, (self.spec.warn_hi - lo) / (hi - lo)))
            p.setPen(QtGui.QPen(_color(WARN), 2))
            p.drawLine(QtCore.QPointF(wx, track.top() - 3),
                       QtCore.QPointF(wx, track.bottom() + 3))
        p.setPen(_color(DIM))
        p.drawText(QtCore.QRectF(12, self.height() - 22, self.width() - 24, 16),
                   Qt.AlignLeft, f"{lo:g}")
        p.drawText(QtCore.QRectF(12, self.height() - 22, self.width() - 24, 16),
                   Qt.AlignRight, f"{hi:g}")
        p.end()


# ── sparkline (history graph) ──────────────────────────────────────────────


class SparklineTile(Tile):
    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        _v, txt, col = self.current(self.state)

        f = self.font()
        f.setPointSizeF(self.font().pointSizeF() * 1.9)
        f.setBold(True)
        p.setFont(f)
        p.setPen(_color(col))
        p.drawText(QtCore.QRectF(12, 20, self.width() - 24, 34),
                   Qt.AlignLeft | Qt.AlignVCenter, f"{txt} {self.unit_text()}")

        hist = self.state.history.get(self.spec.name, ()) if self.spec else ()
        area = QtCore.QRectF(12, 60, self.width() - 24, self.height() - 78)
        p.setPen(QtGui.QPen(_color(TRACK), 1))
        p.setBrush(Qt.NoBrush)
        p.drawRect(area)
        pts = [(t, v) for t, v in hist]
        if len(pts) >= 2:
            vmin = min(v for _, v in pts)
            vmax = max(v for _, v in pts)
            if vmax - vmin < 1e-9:
                vmin -= 0.5
                vmax += 0.5
            t0, t1 = pts[0][0], pts[-1][0]
            tspan = max(1e-9, t1 - t0)
            poly = QtGui.QPolygonF()
            for t, v in pts:
                x = area.left() + (t - t0) / tspan * area.width()
                y = area.bottom() - (v - vmin) / (vmax - vmin) * area.height()
                poly.append(QtCore.QPointF(x, y))
            p.setPen(QtGui.QPen(_color(ACCENT), 2))
            p.drawPolyline(poly)
            p.setPen(_color(DIM))
            small = self.font()
            small.setPointSizeF(self.font().pointSizeF() * 0.8)
            p.setFont(small)
            p.drawText(area.adjusted(4, 0, 0, 0), Qt.AlignTop | Qt.AlignLeft,
                       f"{vmax:.{self.spec.decimals}f}")
            p.drawText(area.adjusted(4, 0, 0, -2), Qt.AlignBottom | Qt.AlignLeft,
                       f"{vmin:.{self.spec.decimals}f}")
        p.end()


# ── 96-cell voltage heatmap ────────────────────────────────────────────────


class CellGridTile(Tile):
    COLS, ROWS = 12, 8

    def __init__(self, cfg, parent=None):
        super().__init__(cfg, parent)
        self.setMinimumSize(330, 190)

    def title_text(self):
        return self.cfg.title or "Cell Voltages (96)"

    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        cells = self.state.cells
        valid = [c for c in cells if is_num(c) and c > 0.5]
        area = QtCore.QRectF(12, 28, self.width() - 24, self.height() - 56)
        cw = area.width() / self.COLS
        ch = area.height() / self.ROWS
        if valid:
            vmin, vmax = min(valid), max(valid)
            spread = max(0.004, vmax - vmin)   # ≥4 mV so noise doesn't rainbow
            for i, v in enumerate(cells):
                x = area.left() + (i % self.COLS) * cw
                y = area.top() + (i // self.COLS) * ch
                r = QtCore.QRectF(x + 1, y + 1, cw - 2, ch - 2)
                if is_num(v) and v > 0.5:
                    f = (v - vmin) / spread
                    color = lerp_color("#2278c8", "#ff7b45", f)  # low→blue high→orange
                else:
                    color = _color("#23272e")
                p.setPen(Qt.NoPen)
                p.setBrush(color)
                p.drawRoundedRect(r, 2, 2)
        else:
            p.setPen(_color(DIM))
            p.drawText(area, Qt.AlignCenter, "waiting for 0x6F2 sweep…")
        # footer: min/avg/max/delta
        p.setPen(_color(DIM))
        if valid:
            txt = (f"min {min(valid):.3f}   avg {sum(valid)/len(valid):.3f}   "
                   f"max {max(valid):.3f}   Δ {(max(valid)-min(valid))*1000:.0f} mV"
                   f"   ({len(valid)}/96)")
            p.drawText(QtCore.QRectF(12, self.height() - 24, self.width() - 24, 18),
                       Qt.AlignCenter, txt)
        p.end()


# ── 16-module temperature grid ─────────────────────────────────────────────


class ModuleTempsTile(Tile):
    def __init__(self, cfg, parent=None):
        super().__init__(cfg, parent)
        self.setMinimumSize(230, 190)

    def title_text(self):
        return self.cfg.title or "Module Temps"

    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        temps = self.state.module_temps
        area = QtCore.QRectF(12, 28, self.width() - 24, self.height() - 40)
        cols, rows = 4, 4
        cw, ch = area.width() / cols, area.height() / rows
        f = self.font()
        f.setPointSizeF(max(7.0, self.font().pointSizeF() * 0.9))
        p.setFont(f)
        for m in range(16):
            t1, t2 = temps[m * 2], temps[m * 2 + 1]
            vals = [t for t in (t1, t2) if is_num(t)]
            x = area.left() + (m % cols) * cw
            y = area.top() + (m // cols) * ch
            r = QtCore.QRectF(x + 2, y + 2, cw - 4, ch - 4)
            if vals:
                avg = sum(vals) / len(vals)
                frac = max(0.0, min(1.0, (avg - 10) / 40.0))   # 10..50 °C scale
                p.setBrush(lerp_color("#1d5f8a", "#d94f35", frac))
                p.setPen(Qt.NoPen)
                p.drawRoundedRect(r, 3, 3)
                p.setPen(_color("#ffffff"))
                p.drawText(r, Qt.AlignCenter, f"{avg:.0f}\N{DEGREE SIGN}")
            else:
                p.setBrush(_color("#23272e"))
                p.setPen(Qt.NoPen)
                p.drawRoundedRect(r, 3, 3)
                p.setPen(_color(DIM))
                p.drawText(r, Qt.AlignCenter, "—")
        p.end()


# ── bench-tester module/brick table ────────────────────────────────────────
# Faithful port of the Flutter bench tester's cell grid
# (lib/screens/dashboard_screen.dart): 16 module rows x 6 brick voltages,
# colored by deviation from pack average, plus per-module Δ spread and temp.

BENCH_HDR = "#90caf9"          # header / module labels
BENCH_LOW2 = "#7f0000"         # brick > 12 mV below average
BENCH_LOW1 = "#7f4000"         # brick > 6 mV below average
BENCH_HIGH = "#0d3b6e"         # brick > 6 mV above average
BENCH_OK = "#1e4d2b"           # within ±6 mV of average
BENCH_NA = "#1a1a2e"           # no data
BENCH_GOOD = "#00e676"
BENCH_WARN = "#ffeb3b"
BENCH_BAD = "#ff1744"


def _bench_cell_color(v: float, avg: float) -> QtGui.QColor:
    dev = (v - avg) * 1000.0
    if dev < -12:
        return _color(BENCH_LOW2)
    if dev < -6:
        return _color(BENCH_LOW1)
    if dev > 6:
        return _color(BENCH_HIGH)
    return _color(BENCH_OK)


def _delta_color(mv: float) -> str:
    if mv <= 20:
        return BENCH_GOOD
    if mv <= 50:
        return BENCH_WARN
    return BENCH_BAD


def _mono_font(base: QtGui.QFont, pt: float, bold: bool = False) -> QtGui.QFont:
    f = QtGui.QFont(base)
    f.setFamily("Consolas")
    f.setStyleHint(QtGui.QFont.TypeWriter)
    f.setPointSizeF(max(6.0, pt))
    f.setBold(bold)
    return f


class ModuleTableTile(Tile):
    # column flex: Mod, C1..C6, Δ, temp — same proportions as the bench tester
    FLEX = (1.1, 2, 2, 2, 2, 2, 2, 1.3, 1.3)

    def __init__(self, cfg, parent=None):
        super().__init__(cfg, parent)
        self.setMinimumSize(430, 430)

    def title_text(self):
        return self.cfg.title or "Modules / Bricks"

    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        st = self.state
        metric = getattr(self, "metric", False)
        avg = st.cell_avg_or_nan()
        if not is_num(avg):
            avg = 4.0

        area = QtCore.QRectF(10, 26, self.width() - 20, self.height() - 34)
        header_h = 16.0
        row_h = (area.height() - header_h) / 16.0
        total_flex = sum(self.FLEX)
        xs, x = [], area.left()
        for fl in self.FLEX:
            w = area.width() * fl / total_flex
            xs.append((x, w))
            x += w

        cell_pt = min(11.0, max(6.5, row_h * 0.42))
        hdr_font = _mono_font(self.font(), cell_pt, bold=True)
        cell_font = _mono_font(self.font(), cell_pt)

        # header
        p.setFont(hdr_font)
        p.setPen(_color(BENCH_HDR))
        headers = ("Mod", "C1", "C2", "C3", "C4", "C5", "C6", "Δ mV",
                   "\N{DEGREE SIGN}C" if metric else "\N{DEGREE SIGN}F")
        for (cx, cw), h in zip(xs, headers):
            p.drawText(QtCore.QRectF(cx, area.top(), cw, header_h),
                       Qt.AlignCenter, h)

        for mod in range(16):
            y = area.top() + header_h + mod * row_h
            # module label
            p.setFont(hdr_font)
            p.setPen(_color(BENCH_HDR))
            p.drawText(QtCore.QRectF(xs[0][0], y, xs[0][1], row_h),
                       Qt.AlignCenter, f"M{mod + 1:02d}")
            # 6 bricks
            p.setFont(cell_font)
            for ci, v in enumerate(st.module_cells(mod)):
                cx, cw = xs[1 + ci]
                r = QtCore.QRectF(cx + 1, y + 1, cw - 2, row_h - 2)
                valid = is_num(v) and v > 0.5
                p.setPen(Qt.NoPen)
                p.setBrush(_bench_cell_color(v, avg) if valid else _color(BENCH_NA))
                p.drawRoundedRect(r, 3, 3)
                p.setPen(_color("#e0e0e0" if valid else DIM))
                p.drawText(r, Qt.AlignCenter, f"{v:.3f}" if valid else "—")
            # module Δ spread
            spread = st.module_spread_mv(mod)
            p.setPen(_color(BENCH_BAD if spread > 10 else
                            BENCH_WARN if spread > 5 else BENCH_GOOD))
            p.drawText(QtCore.QRectF(xs[7][0], y, xs[7][1], row_h),
                       Qt.AlignCenter, f"{spread:.1f}" if spread > 0 else "—")
            # module temp (sensor T1, like the bench tester)
            t1 = st.module_temps[mod * 2]
            if is_num(t1):
                shown = t1 if metric else t1 * 9 / 5 + 32
                txt = f"{shown:.0f}"
            else:
                txt = "—"
            p.setPen(_color("#cfd8dc"))
            p.drawText(QtCore.QRectF(xs[8][0], y, xs[8][1], row_h),
                       Qt.AlignCenter, txt)
        p.end()


class PackDeltaTile(Tile):
    """The bench tester's hero card: pack Δ in mV with min/avg/max bricks."""

    def __init__(self, cfg, parent=None):
        super().__init__(cfg, parent)
        self.setMinimumSize(210, 190)

    def title_text(self):
        return self.cfg.title or "Pack Delta"

    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        st = self.state
        delta = st.num("cell_delta_mv")
        have = is_num(delta) and delta > 0
        col = _delta_color(delta) if have else DIM

        # big Δ value
        f = _mono_font(self.font(), self.font().pointSizeF() * 2.9, bold=True)
        p.setFont(f)
        p.setPen(_color(col))
        p.drawText(QtCore.QRectF(0, 20, self.width(), self.height() * 0.36),
                   Qt.AlignCenter, f"{delta:.1f}" if have else "—")
        p.setFont(_mono_font(self.font(), self.font().pointSizeF(), bold=True))
        p.drawText(QtCore.QRectF(0, 22 + self.height() * 0.36, self.width(), 18),
                   Qt.AlignCenter, "mV")

        # color bar
        bar = QtCore.QRectF(16, self.height() - 66, self.width() - 32, 6)
        p.setPen(Qt.NoPen)
        p.setBrush(_color(col))
        p.drawRoundedRect(bar, 3, 3)

        # min / avg / max with module locations
        vmin, vavg, vmax = (st.num("cell_min"), st.num("cell_avg"),
                            st.num("cell_max"))
        small = _mono_font(self.font(), self.font().pointSizeF() * 0.82)
        tiny = _mono_font(self.font(), self.font().pointSizeF() * 0.72)
        cols = (
            ("MIN", vmin, f"M{st.min_cell_index() // 6 + 1:02d}"),
            ("AVG", vavg, ""),
            ("MAX", vmax, f"M{st.max_cell_index() // 6 + 1:02d}"),
        )
        w3 = (self.width() - 24) / 3
        for i, (label, v, sub) in enumerate(cols):
            x = 12 + i * w3
            p.setFont(tiny)
            p.setPen(_color(DIM))
            p.drawText(QtCore.QRectF(x, self.height() - 54, w3, 13),
                       Qt.AlignCenter, label)
            p.setFont(small)
            p.setPen(_color("#cfd8dc"))
            p.drawText(QtCore.QRectF(x, self.height() - 41, w3, 15),
                       Qt.AlignCenter, f"{v:.4f}V" if is_num(v) else "—")
            if sub and is_num(v):
                p.setFont(tiny)
                p.setPen(_color(DIM))
                p.drawText(QtCore.QRectF(x, self.height() - 26, w3, 13),
                           Qt.AlignCenter, sub)
        p.end()


# ── status / link tile ─────────────────────────────────────────────────────


class StatusTile(Tile):
    def title_text(self):
        return self.cfg.title or "Status"

    def paintEvent(self, ev):
        super().paintEvent(ev)          # stylesheet background + border
        if not hasattr(self, "state"):
            return
        p = self._painter()
        self._draw_title(p)
        st = self.state
        rows = [
            ("Link", st.source_desc or "—"),
            ("Frames", f"{st.num('frame_rate'):.0f}/s" if is_num(st.num('frame_rate')) else "—"),
            ("Serial", str(st.get("serial_number", "—"))[:18] or "—"),
            ("Gear", str(st.get("gear", "—"))),
            ("SoC age", f"{st.age('soc'):.0f}s" if st.age('soc') < 1e9 else "—"),
        ]
        f = self.font()
        f.setPointSizeF(self.font().pointSizeF() * 0.95)
        p.setFont(f)
        y = 30
        lh = max(18, int((self.height() - 40) / len(rows)))
        for label, val in rows:
            p.setPen(_color(DIM))
            p.drawText(QtCore.QRectF(12, y, 80, lh), Qt.AlignLeft | Qt.AlignVCenter, label)
            p.setPen(_color(GOOD if (label == "Link" and st.connected) else FG))
            p.drawText(QtCore.QRectF(95, y, self.width() - 107, lh),
                       Qt.AlignLeft | Qt.AlignVCenter, str(val))
            y += lh
        p.end()


# ── factory ────────────────────────────────────────────────────────────────

TILE_CLASSES = {
    "number": NumberTile,
    "gauge": GaugeTile,
    "bar": BarTile,
    "sparkline": SparklineTile,
    "cellgrid": CellGridTile,
    "modtable": ModuleTableTile,
    "packdelta": PackDeltaTile,
    "modtemps": ModuleTempsTile,
    "status": StatusTile,
}


def make_tile(cfg, parent=None) -> Tile:
    cls = TILE_CLASSES.get(cfg.type, NumberTile)
    return cls(cfg, parent)
