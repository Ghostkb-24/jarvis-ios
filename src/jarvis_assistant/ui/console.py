from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from jarvis_assistant.ui.theme import DraggableGlassWidget


class TaskConsole(DraggableGlassWidget):
    request_submitted = Signal(str)
    confirmation_answered = Signal(str, bool)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setFixedWidth(354)
        self.setMinimumHeight(330)
        self._action_id: str | None = None

        title = QLabel("任务控制台")
        self.provider_label = QLabel("Ollama · 本地")
        self.provider_label.setObjectName("mutedLabel")
        header = QHBoxLayout()
        header.addWidget(title)
        header.addStretch()
        header.addWidget(self.provider_label)

        self.conversation = QTextBrowser()
        self.conversation.setOpenExternalLinks(False)

        self.confirmation_frame = QFrame()
        self.confirmation_frame.setVisible(False)
        self.confirmation_label = QLabel()
        self.confirmation_label.setWordWrap(True)
        self.cancel_button = QPushButton("取消")
        self.allow_button = QPushButton("允许")
        self.allow_button.setObjectName("primaryButton")
        self.cancel_button.clicked.connect(lambda: self._answer_confirmation(False))
        self.allow_button.clicked.connect(lambda: self._answer_confirmation(True))
        confirmation_actions = QHBoxLayout()
        confirmation_actions.addStretch()
        confirmation_actions.addWidget(self.cancel_button)
        confirmation_actions.addWidget(self.allow_button)
        confirmation_layout = QVBoxLayout(self.confirmation_frame)
        confirmation_layout.setContentsMargins(0, 6, 0, 6)
        confirmation_layout.addWidget(self.confirmation_label)
        confirmation_layout.addLayout(confirmation_actions)

        self.input = QLineEdit()
        self.input.setPlaceholderText("输入消息或按 Ctrl + Alt + Space 说话")
        self.send_button = QPushButton("发送")
        self.send_button.setObjectName("primaryButton")
        self.send_button.clicked.connect(self._submit)
        self.input.returnPressed.connect(self._submit)
        input_layout = QHBoxLayout()
        input_layout.addWidget(self.input)
        self.send_button.hide()

        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 15, 16, 15)
        layout.setSpacing(11)
        layout.addLayout(header)
        layout.addWidget(self.conversation)
        layout.addWidget(self.confirmation_frame)
        layout.addLayout(input_layout)
        self.hide()

    def append_message(self, role: str, text: str) -> None:
        safe_role = "你" if role == "user" else "Jarvis"
        self.conversation.append(f"<b>{safe_role}</b><br>{text}")

    def show_confirmation(self, action_id: str, summary: str) -> None:
        self._action_id = action_id
        self.confirmation_label.setText(summary)
        self.confirmation_frame.setVisible(True)
        self.show()

    def _answer_confirmation(self, allowed: bool) -> None:
        if self._action_id is None:
            return
        action_id = self._action_id
        self._action_id = None
        self.confirmation_frame.setVisible(False)
        self.confirmation_answered.emit(action_id, allowed)

    def _submit(self) -> None:
        text = self.input.text().strip()
        if not text:
            return
        self.input.clear()
        self.append_message("user", text)
        self.request_submitted.emit(text)
