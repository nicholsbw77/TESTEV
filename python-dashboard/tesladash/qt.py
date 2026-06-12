"""Qt binding shim.

Prefers PySide6 (modern desktops / 64-bit SBCs) and falls back to PyQt5,
which is the realistic option on older 32-bit ARM boards (Tegra-class
hardware, older Raspberry Pi OS images) where PySide6 wheels don't exist.

Import Qt from here everywhere:

    from .qt import QtCore, QtGui, QtWidgets, Signal, qexec
"""

try:
    from PySide6 import QtCore, QtGui, QtWidgets  # noqa: F401
    from PySide6.QtCore import Signal, Slot  # noqa: F401

    QT_BINDING = "PySide6"
except ImportError:  # pragma: no cover - exercised only where PySide6 is absent
    try:
        from PyQt5 import QtCore, QtGui, QtWidgets  # noqa: F401
        from PyQt5.QtCore import pyqtSignal as Signal  # noqa: F401
        from PyQt5.QtCore import pyqtSlot as Slot  # noqa: F401

        QT_BINDING = "PyQt5"
    except ImportError as exc:
        raise ImportError(
            "No Qt binding found. Install one of:\n"
            "  pip install PySide6      (desktop / 64-bit ARM)\n"
            "  pip install PyQt5        (older 32-bit ARM boards)"
        ) from exc


def qexec(obj, *args):
    """Call .exec()/.exec_() across bindings (QApplication, QDialog, QMenu, QDrag)."""
    fn = getattr(obj, "exec", None) or getattr(obj, "exec_")
    return fn(*args)
