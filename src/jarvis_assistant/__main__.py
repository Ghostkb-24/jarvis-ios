from __future__ import annotations

import sys

from PySide6.QtWidgets import QApplication

from jarvis_assistant.app import build_application


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Jarvis Desktop Assistant")
    app.setQuitOnLastWindowClosed(False)
    runtime = build_application()
    app.aboutToQuit.connect(runtime.shutdown)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
