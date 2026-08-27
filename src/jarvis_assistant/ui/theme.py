from __future__ import annotations

from PySide6.QtCore import QPoint, Qt
from PySide6.QtGui import QMouseEvent, QPainter, QPaintEvent
from PySide6.QtWidgets import QStyle, QStyleOption, QWidget

WINDOW_STYLE = """
QWidget#glassSurface {
    background-color: rgba(238, 243, 247, 224);
    color: #1d2b38;
    border: 1px solid rgba(255, 255, 255, 220);
    border-radius: 16px;
    font-family: "Microsoft YaHei UI", "Segoe UI";
}
QLabel#mutedLabel { color: #6e7e8d; }
QPushButton {
    background-color: rgba(255, 255, 255, 225);
    color: #1d2b38;
    border: 0;
    border-radius: 8px;
    padding: 6px 10px;
}
QPushButton:hover { background-color: #ffffff; }
QPushButton#primaryButton { background-color: #356db7; color: #ffffff; }
QPushButton#primaryButton:hover { background-color: #2d61a6; }
QLineEdit, QTextBrowser, QComboBox {
    background-color: rgba(255, 255, 255, 205);
    color: #1d2b38;
    border: 1px solid rgba(255, 255, 255, 235);
    border-radius: 10px;
    padding: 7px;
}
QLineEdit { min-height: 24px; }
QTextBrowser { selection-background-color: #cdddf2; }
"""


class DraggableGlassWidget(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("glassSurface")
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground)
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

    def paintEvent(self, event: QPaintEvent) -> None:
        option = QStyleOption()
        option.initFrom(self)
        painter = QPainter(self)
        self.style().drawPrimitive(
            QStyle.PrimitiveElement.PE_Widget,
            option,
            painter,
            self,
        )
        painter.end()
        super().paintEvent(event)

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
