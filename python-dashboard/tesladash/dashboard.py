"""Main window: a grid of tiles plus a thin top bar.

Customization model:
  * Edit mode (menu, or press E): tiles get a dashed border, an ✕ remove
    button, and can be dragged onto each other to reorder. "+ Add tile"
    opens a dialog listing every signal in the catalog.
  * Layout persists to JSON on exit / on leaving edit mode (config.py).
  * F11 fullscreen (kiosk for the in-car LCD), Ctrl+Q quits.
"""

import time

from .qt import QtCore, QtGui, QtWidgets, qexec
from . import config as cfgmod
from .config import DashConfig, TileConfig
from .signals import SIGNALS
from .state import VehicleState
from .widgets import BG, DIM, FG, GOOD, ALERT, Tile, make_tile

Qt = QtCore.Qt
MIME = "application/x-tesladash-tile"


# ── Add-tile dialog ────────────────────────────────────────────────────────


class AddTileDialog(QtWidgets.QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Add tile")
        form = QtWidgets.QFormLayout(self)

        self.type_box = QtWidgets.QComboBox()
        self.type_box.addItems(["gauge", "number", "bar", "sparkline",
                                "cellgrid", "modtable", "packdelta",
                                "modtemps", "status"])

        self.signal_box = QtWidgets.QComboBox()
        for name, spec in sorted(SIGNALS.items(), key=lambda kv: kv[1].label):
            mark = "✓" if spec.verified else "⚠"
            self.signal_box.addItem(f"{mark} {spec.label} [{spec.unit}]", name)
            idx = self.signal_box.count() - 1
            self.signal_box.setItemData(idx, spec.source, Qt.ToolTipRole)

        self.title_edit = QtWidgets.QLineEdit()
        self.title_edit.setPlaceholderText("(default)")
        self.lo_edit = QtWidgets.QLineEdit()
        self.hi_edit = QtWidgets.QLineEdit()
        self.lo_edit.setPlaceholderText("auto")
        self.hi_edit.setPlaceholderText("auto")
        self.hint = QtWidgets.QLabel("")
        self.hint.setWordWrap(True)
        self.hint.setStyleSheet(f"color: {DIM};")

        form.addRow("Tile type", self.type_box)
        form.addRow("Signal", self.signal_box)
        form.addRow("Title", self.title_edit)
        form.addRow("Range min", self.lo_edit)
        form.addRow("Range max", self.hi_edit)
        form.addRow(self.hint)

        btns = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.Ok | QtWidgets.QDialogButtonBox.Cancel)
        btns.accepted.connect(self.accept)
        btns.rejected.connect(self.reject)
        form.addRow(btns)

        self.signal_box.currentIndexChanged.connect(self._update_hint)
        self.type_box.currentTextChanged.connect(self._update_hint)
        self._update_hint()

    def _update_hint(self):
        name = self.signal_box.currentData()
        spec = SIGNALS.get(name)
        needs_signal = self.type_box.currentText() not in (
            "cellgrid", "modtable", "packdelta", "modtemps", "status")
        self.signal_box.setEnabled(needs_signal)
        if spec and needs_signal:
            v = "verified on this car" if spec.verified else "community decode — verify!"
            self.hint.setText(f"{spec.source}\n({v})")
        else:
            self.hint.setText("")

    def tile_config(self) -> TileConfig:
        t = self.type_box.currentText()
        signal = self.signal_box.currentData() if self.signal_box.isEnabled() else ""

        def _f(edit):
            try:
                return float(edit.text())
            except ValueError:
                return None

        return TileConfig(type=t, signal=signal or "",
                          title=self.title_edit.text().strip(),
                          lo=_f(self.lo_edit), hi=_f(self.hi_edit),
                          span=2 if t in ("cellgrid", "modtable") else 1)


# ── tile grid with drag-drop reorder ───────────────────────────────────────


class DashboardArea(QtWidgets.QWidget):
    def __init__(self, window: "MainWindow"):
        super().__init__()
        self.win = window
        self.grid = QtWidgets.QGridLayout(self)
        self.grid.setContentsMargins(10, 6, 10, 10)
        self.grid.setSpacing(10)
        self.tiles: list[Tile] = []
        self.setAcceptDrops(True)

    def rebuild(self):
        for t in self.tiles:
            self.grid.removeWidget(t)
            t.deleteLater()
        self.tiles = []
        cfg = self.win.cfg
        row = col = 0
        for i, tc in enumerate(cfg.tiles):
            tile = make_tile(tc, self)
            tile.index = i
            tile.remove_requested = self.win.remove_tile
            tile.set_edit_mode(self.win.edit_mode)
            span = max(1, min(tc.span, cfg.columns))
            if col + span > cfg.columns:
                row, col = row + 1, 0
            self.grid.addWidget(tile, row, col, 1, span)
            col += span
            if col >= cfg.columns:
                row, col = row + 1, 0
            self.tiles.append(tile)
        for c in range(cfg.columns):
            self.grid.setColumnStretch(c, 1)

    def refresh(self, state: VehicleState):
        for t in self.tiles:
            t.refresh(state, self.win.cfg.metric)

    # — drop handling: reorder cfg.tiles, then rebuild —

    def dragEnterEvent(self, ev):
        if ev.mimeData().hasFormat(MIME):
            ev.acceptProposedAction()

    def dragMoveEvent(self, ev):
        if ev.mimeData().hasFormat(MIME):
            ev.acceptProposedAction()

    def dropEvent(self, ev):
        if not ev.mimeData().hasFormat(MIME):
            return
        src = int(bytes(ev.mimeData().data(MIME)).decode())
        pos = ev.position().toPoint() if hasattr(ev, "position") else ev.pos()
        dst = src
        for t in self.tiles:
            if t.geometry().contains(pos):
                dst = t.index
                break
        else:
            dst = len(self.tiles) - 1
        tiles = self.win.cfg.tiles
        if 0 <= src < len(tiles) and dst != src:
            tiles.insert(dst, tiles.pop(src))
            self.rebuild()
        ev.acceptProposedAction()


# ── main window ────────────────────────────────────────────────────────────


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, state: VehicleState, cfg: DashConfig, cfg_path: str):
        super().__init__()
        self.state = state
        self.cfg = cfg
        self.cfg_path = cfg_path
        self.edit_mode = False

        self.setWindowTitle("TESTEV — Model S Dashboard")
        self.setStyleSheet(
            f"QMainWindow, QWidget {{ background: {BG}; color: {FG}; }}"
            f"QMenu {{ background: #1c2128; color: {FG}; }}"
            f"QMenu::item:selected {{ background: #2d3540; }}")

        central = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(central)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)

        v.addWidget(self._build_topbar())

        self.area = DashboardArea(self)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        scroll.setWidget(self.area)
        v.addWidget(scroll, 1)
        self.setCentralWidget(central)
        self.area.rebuild()

        # keyboard shortcuts (QShortcut lives in QtGui on Qt6, QtWidgets on Qt5)
        Shortcut = getattr(QtGui, "QShortcut", None) or QtWidgets.QShortcut
        Shortcut(QtGui.QKeySequence("E"), self, self.toggle_edit)
        Shortcut(QtGui.QKeySequence("F11"), self, self.toggle_fullscreen)
        Shortcut(QtGui.QKeySequence("Ctrl+Q"), self, self.close)

    # — top bar —

    def _build_topbar(self) -> QtWidgets.QWidget:
        bar = QtWidgets.QWidget()
        bar.setFixedHeight(34)
        h = QtWidgets.QHBoxLayout(bar)
        h.setContentsMargins(12, 0, 8, 0)

        title = QtWidgets.QLabel("TESTEV")
        title.setStyleSheet(f"color: {DIM}; font-weight: bold; letter-spacing: 2px;")
        self.link_dot = QtWidgets.QLabel("●")
        self.link_label = QtWidgets.QLabel("")
        self.link_label.setStyleSheet(f"color: {DIM};")
        self.clock = QtWidgets.QLabel("")
        self.clock.setStyleSheet(f"color: {FG}; font-weight: bold;")
        menu_btn = QtWidgets.QToolButton()
        menu_btn.setText("☰")
        menu_btn.setStyleSheet(
            f"QToolButton {{ color: {FG}; background: transparent; border: none;"
            " font-size: 18px; padding: 0 8px; }")
        menu_btn.clicked.connect(lambda: self._show_menu(menu_btn))

        h.addWidget(title)
        h.addSpacing(14)
        h.addWidget(self.link_dot)
        h.addWidget(self.link_label)
        h.addStretch(1)
        h.addWidget(self.clock)
        h.addSpacing(10)
        h.addWidget(menu_btn)
        return bar

    def _show_menu(self, anchor):
        m = QtWidgets.QMenu(self)
        m.addAction("✎ Edit layout" if not self.edit_mode else "✓ Done editing",
                    self.toggle_edit)
        m.addAction("+ Add tile…", self.add_tile)
        m.addSeparator()
        cols = m.addMenu("Columns")
        for n in (3, 4, 5, 6):
            act = cols.addAction(f"{n}{'  ●' if self.cfg.columns == n else ''}")
            act.triggered.connect(lambda _=False, n=n: self.set_columns(n))
        m.addAction(("Units: metric" if self.cfg.metric else "Units: imperial")
                    + " (toggle)", self.toggle_units)
        m.addSeparator()
        m.addAction("Save layout", self.save_layout)
        m.addAction("Fullscreen (F11)", self.toggle_fullscreen)
        m.addAction("Quit (Ctrl+Q)", self.close)
        qexec(m, anchor.mapToGlobal(QtCore.QPoint(0, anchor.height())))

    # — actions —

    def toggle_edit(self):
        self.edit_mode = not self.edit_mode
        for t in self.area.tiles:
            t.set_edit_mode(self.edit_mode)
        if not self.edit_mode:
            self.save_layout()

    def add_tile(self):
        dlg = AddTileDialog(self)
        if qexec(dlg) == QtWidgets.QDialog.Accepted:
            self.cfg.tiles.append(dlg.tile_config())
            self.area.rebuild()

    def remove_tile(self, tile: Tile):
        if 0 <= tile.index < len(self.cfg.tiles):
            self.cfg.tiles.pop(tile.index)
            self.area.rebuild()

    def set_columns(self, n: int):
        self.cfg.columns = n
        self.area.rebuild()

    def toggle_units(self):
        self.cfg.metric = not self.cfg.metric

    def save_layout(self):
        cfgmod.save(self.cfg, self.cfg_path)

    def toggle_fullscreen(self):
        if self.isFullScreen():
            self.showNormal()
        else:
            self.showFullScreen()

    def closeEvent(self, ev):
        self.save_layout()
        super().closeEvent(ev)

    # — periodic UI refresh, driven by app.py —

    def tick(self):
        self.area.refresh(self.state)
        self.clock.setText(time.strftime("%H:%M"))
        ok = self.state.connected
        self.link_dot.setStyleSheet(f"color: {GOOD if ok else ALERT};")
        self.link_label.setText(self.state.source_desc)
