from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget

from jarvis_assistant.ui.theme import DraggableGlassWidget


class CompactSidebar(DraggableGlassWidget):
    expand_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setFixedWidth(190)
        self.setMinimumHeight(148)

        title = QLabel("Jarvis")
        self.model_label = QLabel("本地")
        self.model_label.setObjectName("mutedLabel")
        header = QHBoxLayout()
        header.addWidget(title)
        header.addStretch()
        header.addWidget(self.model_label)

        self.result_label = QLabel("准备就绪")
        self.result_label.setWordWrap(True)
        self.open_latest_button = QPushButton("打开最新")
        self.expand_button = QPushButton("展开")
        self.open_latest_button.clicked.connect(self.expand_requested)
        self.expand_button.clicked.connect(self.expand_requested)

        actions = QHBoxLayout()
        actions.addWidget(self.open_latest_button)
        actions.addWidget(self.expand_button)
        actions.addStretch()

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 13, 14, 13)
        layout.setSpacing(10)
        layout.addLayout(header)
        layout.addWidget(self.result_label)
        layout.addLayout(actions)

    def set_status(self, text: str, *, model: str | None = None) -> None:
        self.result_label.setText(text)
        if model is not None:
            self.model_label.setText(model)
