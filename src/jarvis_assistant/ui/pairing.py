from __future__ import annotations

import json
from typing import Any

import qrcode
from PySide6.QtCore import Qt
from PySide6.QtGui import QImage, QPainter, QPixmap
from PySide6.QtWidgets import QDialog, QLabel, QVBoxLayout, QWidget
from qrcode.constants import ERROR_CORRECT_M


class PairingQrDialog(QDialog):
    def __init__(self, payload: dict[str, Any], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("iPhone 配对")
        self.setModal(False)
        self.qr_label = QLabel()
        self.qr_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.qr_label.setAccessibleName("iPhone 配对二维码")
        self.qr_label.setPixmap(_render_qr(payload))
        instruction = QLabel("请使用 Jarvis iPhone App 扫描此二维码")
        instruction.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout = QVBoxLayout(self)
        layout.addWidget(self.qr_label)
        layout.addWidget(instruction)


def _render_qr(payload: dict[str, Any]) -> QPixmap:
    encoded = json.dumps(
        payload,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    )
    qr = qrcode.QRCode(error_correction=ERROR_CORRECT_M, border=4, box_size=1)
    qr.add_data(encoded)
    qr.make(fit=True)
    matrix = qr.get_matrix()
    scale = max(4, 320 // len(matrix))
    image = QImage(
        len(matrix) * scale,
        len(matrix) * scale,
        QImage.Format.Format_RGB32,
    )
    image.fill(Qt.GlobalColor.white)
    painter = QPainter(image)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(Qt.GlobalColor.black)
    for y, row in enumerate(matrix):
        for x, filled in enumerate(row):
            if filled:
                painter.drawRect(x * scale, y * scale, scale, scale)
    painter.end()
    return QPixmap.fromImage(image)
