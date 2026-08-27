from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget

from jarvis_assistant.ui.theme import DraggableGlassWidget


class CompactSidebar(DraggableGlassWidget):
    expand_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setFixedWidth(220)
        self.setMinimumHeight(118)

        title = QLabel("Jarvis")
        self.model_label = QLabel("本地 · qwen2.5:3b")
        self.model_label.setObjectName("mutedLabel")
        header = QHBoxLayout()
        header.addWidget(title)
        header.addStretch()
        header.addWidget(self.model_label)

        self.result_label = QLabel("准备就绪")
        self.result_label.setWordWrap(True)
        self.expand_button = QPushButton("展开")
        self.expand_button.clicked.connect(self.expand_requested)

        actions = QHBoxLayout()
        actions.addStretch()
        actions.addWidget(self.expand_button)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(13, 11, 13, 11)
        layout.addLayout(header)
        layout.addWidget(self.result_label)
        layout.addLayout(actions)

    def set_status(self, text: str, *, model: str | None = None) -> None:
        self.result_label.setText(text)
        if model is not None:
            self.model_label.setText(model)
