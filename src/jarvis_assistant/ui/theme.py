from __future__ import annotations

from PySide6.QtCore import QPoint, Qt
from PySide6.QtGui import QMouseEvent
from PySide6.QtWidgets import QWidget

WINDOW_STYLE = """
QWidget#glassSurface {
    background-color: rgba(5, 7, 10, 184);
    color: #ffffff;
    border: 1px solid rgba(255, 255, 255, 32);
    border-radius: 14px;
    font-family: "Microsoft YaHei UI", "Segoe UI";
}
QLabel#mutedLabel { color: rgba(255, 255, 255, 150); }
QPushButton {
    background-color: rgba(255, 255, 255, 24);
    color: #ffffff;
    border: 0;
    border-radius: 7px;
    padding: 6px 10px;
}
QPushButton:hover { background-color: rgba(255, 255, 255, 40); }
QPushButton#primaryButton { background-color: rgba(255, 255, 255, 235); color: #0b0d11; }
QLineEdit, QTextBrowser, QComboBox {
    background-color: rgba(255, 255, 255, 18);
    color: #ffffff;
    border: 1px solid rgba(255, 255, 255, 22);
    border-radius: 8px;
    padding: 7px;
}
"""


class DraggableGlassWidget(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("glassSurface")
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
        )
        self.setStyleSheet(WINDOW_STYLE)
        self._drag_offset: QPoint | None = None

    def set_always_on_top(self, enabled: bool) -> None:
        flags = self.windowFlags()
        if enabled:
            flags |= Qt.WindowType.WindowStaysOnTopHint
        else:
            flags &= ~Qt.WindowType.WindowStaysOnTopHint
        self.setWindowFlags(flags)

    def set_click_through(self, enabled: bool) -> None:
        self.setWindowFlag(Qt.WindowType.WindowTransparentForInput, enabled)
        if self.isVisible():
            self.show()

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() is Qt.MouseButton.LeftButton:
            self._drag_offset = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._drag_offset is not None and event.buttons() & Qt.MouseButton.LeftButton:
            self.move(event.globalPosition().toPoint() - self._drag_offset)
            event.accept()
            return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        self._drag_offset = None
        super().mouseReleaseEvent(event)
