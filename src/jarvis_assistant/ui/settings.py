from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QFormLayout,
    QLineEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


class SettingsDialog(QDialog):
    settings_saved = Signal(dict)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Jarvis 设置")
        self.setMinimumWidth(420)
        self.ollama_model = QLineEdit("qwen2.5:3b")
        self.openai_key = QLineEdit()
        self.openai_key.setEchoMode(QLineEdit.EchoMode.Password)
        self.always_on_top = QCheckBox()
        self.always_on_top.setChecked(False)
        self.click_through = QCheckBox()

        form = QFormLayout()
        form.addRow("Ollama 模型", self.ollama_model)
        form.addRow("OpenAI API Key", self.openai_key)
        form.addRow("始终置顶", self.always_on_top)
        form.addRow("鼠标穿透", self.click_through)

        save = QPushButton("保存")
        save.clicked.connect(self._save)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(save)

    def _save(self) -> None:
        self.settings_saved.emit(
            {
                "ollama_model": self.ollama_model.text().strip(),
                "openai_key": self.openai_key.text(),
                "always_on_top": self.always_on_top.isChecked(),
                "click_through": self.click_through.isChecked(),
            }
        )
        self.accept()
