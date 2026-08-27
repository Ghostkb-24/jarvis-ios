from __future__ import annotations

import asyncio
import os
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal, Slot
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QStyle, QSystemTrayIcon

from jarvis_assistant.audio import (
    AudioError,
    AudioRecorder,
    FasterWhisperTranscriber,
    SoundDeviceBackend,
)
from jarvis_assistant.domain import Settings
from jarvis_assistant.models import OllamaProvider, OpenAIProvider, ProviderRouter
from jarvis_assistant.orchestrator import EventKind, Orchestrator, OrchestratorEvent
from jarvis_assistant.security import SecurityPolicy
from jarvis_assistant.storage import CredentialStore, SQLiteStore
from jarvis_assistant.tools import default_registry
from jarvis_assistant.ui.capsule import VoiceCapsule
from jarvis_assistant.ui.console import TaskConsole
from jarvis_assistant.ui.settings import SettingsDialog
from jarvis_assistant.ui.sidebar import CompactSidebar


class QtClipboardAdapter:
    def read(self) -> str:
        return QApplication.clipboard().text()

    def write(self, text: str) -> None:
        QApplication.clipboard().setText(text)


class WorkerSignals(QObject):
    succeeded = Signal(object)
    failed = Signal(str)


class WorkerTask(QRunnable):
    def __init__(self, function: Callable[[], Any]) -> None:
        super().__init__()
        self.function = function
        self.signals = WorkerSignals()

    @Slot()
    def run(self) -> None:
        try:
            self.signals.succeeded.emit(self.function())
        except Exception as error:
            self.signals.failed.emit(str(error))


class NoopHotkey:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


class MemoryCredentialStore:
    def __init__(self) -> None:
        self._key: str | None = None

    def get_openai_key(self) -> str | None:
        return self._key

    def set_openai_key(self, value: str | None) -> None:
        self._key = value or None


class PynputHotkey:
    def __init__(self, callback: Callable[[], None]) -> None:
        try:
            from pynput import keyboard
        except ImportError as error:
            raise RuntimeError("尚未安装全局快捷键组件 pynput。") from error
        self._listener = keyboard.GlobalHotKeys({"<ctrl>+<alt>+<space>": callback})
        self._listener.start()
        self.closed = False

    def close(self) -> None:
        if self.closed:
            return
        self._listener.stop()
        self.closed = True


class HotkeyBridge(QObject):
    activated = Signal()


class ApplicationRuntime(QObject):
    def __init__(
        self,
        *,
        store: SQLiteStore,
        credentials: CredentialStore | MemoryCredentialStore,
        orchestrator: Orchestrator,
        local_provider: OllamaProvider,
        cloud_provider: OpenAIProvider,
        hotkey: NoopHotkey | PynputHotkey,
        bridge: HotkeyBridge,
        recorder: AudioRecorder,
        transcriber: FasterWhisperTranscriber,
    ) -> None:
        super().__init__()
        self.store = store
        self.credentials = credentials
        self.orchestrator = orchestrator
        self.local_provider = local_provider
        self.cloud_provider = cloud_provider
        self.hotkey = hotkey
        self.bridge = bridge
        self.recorder = recorder
        self.transcriber = transcriber
        self.sidebar = CompactSidebar()
        self.console = TaskConsole()
        self.capsule = VoiceCapsule()
        self.settings_dialog = SettingsDialog()
        self.tray = QSystemTrayIcon()
        self.paused = False
        self.closed = False
        self._tasks: set[WorkerTask] = set()
        self._pending_kinds: dict[str, EventKind] = {}

        self._configure_tray()
        self._place_windows()
        self._connect_signals()

    def _configure_tray(self) -> None:
        icon = QApplication.style().standardIcon(QStyle.StandardPixmap.SP_ComputerIcon)
        self.tray.setIcon(QIcon(icon))
        menu = QMenu()
        actions = (
            ("打开控制台", self.console.show),
            ("开始说话", self.toggle_recording),
            ("暂停助手", self.toggle_pause),
            ("设置", self.settings_dialog.show),
            ("退出", self.shutdown),
        )
        for label, callback in actions:
            action = QAction(label, menu)
            action.triggered.connect(callback)
            menu.addAction(action)
        self.tray.setContextMenu(menu)
        self.tray.show()

    def _place_windows(self) -> None:
        screen = QApplication.primaryScreen()
        if screen is None:
            return
        area = screen.availableGeometry()
        settings = self.store.load_settings()
        self.sidebar.move(
            settings.sidebar_x if settings.sidebar_x is not None else area.left() + 18,
            settings.sidebar_y if settings.sidebar_y is not None else area.top() + 18,
        )
        self.console.move(
            settings.console_x
            if settings.console_x is not None
            else area.right() - self.console.width() - 18,
            settings.console_y if settings.console_y is not None else area.top() + 18,
        )
        self.capsule.move(
            settings.capsule_x
            if settings.capsule_x is not None
            else area.center().x() - self.capsule.width() // 2,
            settings.capsule_y
            if settings.capsule_y is not None
            else area.bottom() - self.capsule.height() - 18,
        )

    def _connect_signals(self) -> None:
        self.sidebar.expand_requested.connect(self.console.show)
        self.console.request_submitted.connect(self.submit_text)
        self.console.confirmation_answered.connect(self.answer_confirmation)
        self.bridge.activated.connect(self.toggle_recording)
        self.settings_dialog.settings_saved.connect(self.save_settings)

    @Slot()
    def toggle_pause(self) -> None:
        self.paused = not self.paused
        self.sidebar.set_status("助手已暂停" if self.paused else "准备就绪")

    @Slot(str)
    def submit_text(self, text: str) -> None:
        if self.paused:
            self.sidebar.set_status("助手已暂停")
            return
        self.capsule.show_phase("正在思考…")
        self._run_background(
            lambda: asyncio.run(self.orchestrator.submit(text)),
            self._handle_events,
        )

    @Slot(str, bool)
    def answer_confirmation(self, action_id: str, allowed: bool) -> None:
        if not allowed:
            self._pending_kinds.pop(action_id, None)
            self._handle_events([self.orchestrator.cancel(action_id)])
            return
        kind = self._pending_kinds.pop(action_id, None)
        if kind is EventKind.FALLBACK_AVAILABLE:
            operation = self.orchestrator.use_cloud(action_id)
        else:
            operation = self.orchestrator.confirm(action_id)
        self._run_background(
            lambda: asyncio.run(operation),
            self._handle_events,
        )

    @Slot()
    def toggle_recording(self) -> None:
        if self.paused:
            return
        try:
            if not self.recorder.recording:
                self.recorder.start()
                self.capsule.show_phase("正在聆听…")
                return
            buffer = self.recorder.stop()
            self.capsule.show_phase("正在识别…")
            self._run_background(
                lambda: self.transcriber.transcribe(buffer),
                self._handle_transcript,
            )
        except AudioError as error:
            self._show_error(str(error))

    def _handle_transcript(self, text: object) -> None:
        transcript = str(text)
        self.console.append_message("user", transcript)
        self.submit_text(transcript)

    def _handle_events(self, result: object) -> None:
        events = list(result) if isinstance(result, list) else []
        for event in events:
            if not isinstance(event, OrchestratorEvent):
                continue
            if event.kind in {
                EventKind.CONFIRMATION_REQUIRED,
                EventKind.FALLBACK_AVAILABLE,
            } and event.action_id:
                self._pending_kinds[event.action_id] = event.kind
                self.console.show_confirmation(event.action_id, event.message)
            elif event.kind in {
                EventKind.COMPLETED,
                EventKind.FAILED,
                EventKind.REJECTED,
                EventKind.CANCELLED,
            }:
                self.console.append_message("assistant", event.message)
                self.sidebar.set_status(event.message)
        self.capsule.hide()

    def _run_background(
        self,
        function: Callable[[], Any],
        on_success: Callable[[object], None],
    ) -> None:
        task = WorkerTask(function)
        self._tasks.add(task)
        task.signals.succeeded.connect(on_success)
        task.signals.failed.connect(self._show_error)
        task.signals.succeeded.connect(lambda _: self._tasks.discard(task))
        task.signals.failed.connect(lambda _: self._tasks.discard(task))
        QThreadPool.globalInstance().start(task)

    def _show_error(self, message: str) -> None:
        self.capsule.hide()
        self.console.append_message("assistant", message)
        self.console.show()
        self.sidebar.set_status(message)

    @Slot(dict)
    def save_settings(self, values: dict[str, Any]) -> None:
        current = self.store.load_settings()
        updated = current.model_copy(
            update={
                "ollama_model": str(values["ollama_model"]),
                "always_on_top": bool(values["always_on_top"]),
                "click_through": bool(values["click_through"]),
            }
        )
        updated = Settings.model_validate(updated)
        self.store.save_settings(updated)
        self.credentials.set_openai_key(str(values.get("openai_key") or "") or None)
        for window in (self.sidebar, self.console, self.capsule):
            window.set_always_on_top(updated.always_on_top)
            window.set_click_through(updated.click_through)
        self.sidebar.set_status("设置已保存，模型配置重启后生效。")

    @Slot()
    def shutdown(self) -> None:
        if self.closed:
            return
        self.closed = True
        self._persist_window_state()
        self.hotkey.close()
        if self.recorder.recording:
            with suppress(AudioError):
                self.recorder.stop()
        self.tray.hide()
        self.sidebar.close()
        self.console.close()
        self.capsule.close()
        self.settings_dialog.close()
        self.store.close()

    def _persist_window_state(self) -> None:
        settings = self.store.load_settings().model_copy(
            update={
                "sidebar_x": self.sidebar.x(),
                "sidebar_y": self.sidebar.y(),
                "console_x": self.console.x(),
                "console_y": self.console.y(),
                "capsule_x": self.capsule.x(),
                "capsule_y": self.capsule.y(),
            }
        )
        self.store.save_settings(Settings.model_validate(settings))


def build_application(
    *,
    data_dir: str | Path | None = None,
    test_mode: bool = False,
) -> ApplicationRuntime:
    app = QApplication.instance()
    if app is None:
        raise RuntimeError("QApplication must be created before build_application")
    base_dir = Path(data_dir) if data_dir else _default_data_dir()
    base_dir.mkdir(parents=True, exist_ok=True)
    store = SQLiteStore.open(base_dir / "state.db")
    settings = store.load_settings()
    credentials: CredentialStore | MemoryCredentialStore
    credentials = MemoryCredentialStore() if test_mode else CredentialStore()
    api_key = None
    if not test_mode:
        try:
            api_key = credentials.get_openai_key()
        except Exception:
            api_key = None

    registry = default_registry(
        allowed_search_roots=settings.allowed_search_roots,
        clipboard=QtClipboardAdapter(),
    )
    local = OllamaProvider(base_url=settings.ollama_url, model=settings.ollama_model)
    cloud = OpenAIProvider(api_key=api_key, model=settings.openai_model)
    orchestrator = Orchestrator(
        local_provider=local,
        cloud_provider=cloud if api_key else None,
        router=ProviderRouter(openai_available=api_key is not None),
        security=SecurityPolicy(registry),
        registry=registry,
        store=store,
    )
    bridge = HotkeyBridge()
    hotkey: NoopHotkey | PynputHotkey
    hotkey = NoopHotkey() if test_mode else PynputHotkey(bridge.activated.emit)
    runtime = ApplicationRuntime(
        store=store,
        credentials=credentials,
        orchestrator=orchestrator,
        local_provider=local,
        cloud_provider=cloud,
        hotkey=hotkey,
        bridge=bridge,
        recorder=AudioRecorder(SoundDeviceBackend(device=settings.microphone_name)),
        transcriber=FasterWhisperTranscriber(),
    )
    if settings.sidebar_visible:
        runtime.sidebar.show()
    return runtime


def _default_data_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("LOCALAPPDATA is unavailable")
    return Path(local_app_data) / "JarvisDesktopAssistant"
