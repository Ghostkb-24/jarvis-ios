from __future__ import annotations

from PySide6.QtWidgets import QHBoxLayout, QLabel, QWidget

from jarvis_assistant.ui.theme import DraggableGlassWidget


class VoiceCapsule(DraggableGlassWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setFixedSize(250, 52)
        self.dot_label = QLabel("●")
        self.phase_label = QLabel("准备就绪")
        self.hint_label = QLabel("Esc 取消")
        self.hint_label.setObjectName("mutedLabel")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(15, 8, 15, 8)
        layout.addWidget(self.dot_label)
        layout.addWidget(self.phase_label)
        layout.addStretch()
        layout.addWidget(self.hint_label)
        self.hide()

    def show_phase(self, text: str) -> None:
        self.phase_label.setText(text)
        self.show()
