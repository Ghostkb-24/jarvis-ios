from __future__ import annotations

from PySide6.QtWidgets import QHBoxLayout, QLabel, QWidget

from jarvis_assistant.ui.theme import DraggableGlassWidget


class VoiceCapsule(DraggableGlassWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setFixedSize(178, 46)
        self.dot_label = QLabel("●")
        self.dot_label.setStyleSheet("color: #356db7; font-size: 18px;")
        self.phase_label = QLabel("准备就绪")
        self.hint_label = QLabel("Esc 取消")
        self.hint_label.setObjectName("mutedLabel")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(12, 7, 12, 7)
        layout.setSpacing(6)
        layout.addWidget(self.dot_label)
        layout.addWidget(self.phase_label)
        layout.addStretch()
        layout.addWidget(self.hint_label)
        self.hide()

    def show_phase(self, text: str) -> None:
        self.phase_label.setText(text)
        self.show()
