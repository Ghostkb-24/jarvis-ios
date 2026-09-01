from __future__ import annotations

import asyncio
import os
import sys
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from PySide6.QtCore import QObject, QRunnable, QThreadPool, QTimer, Signal, Slot
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QStyle, QSystemTrayIcon

from jarvis_assistant.audio import (
    AudioError,
    AudioRecorder,
    FasterWhisperTranscriber,
    SoundDeviceBackend,
)
from jarvis_assistant.domain import Settings
from jarvis_assistant.models import ModelRequest, OllamaProvider, OpenAIProvider, ProviderRouter
from jarvis_assistant.orchestrator import EventKind, Orchestrator, OrchestratorEvent
from jarvis_assistant.security import SecurityPolicy
from jarvis_assistant.storage import CredentialStore, SQLiteStore
from jarvis_assistant.tools import default_registry
from jarvis_assistant.ui.capsule import VoiceCapsule
from jarvis_assistant.ui.console import TaskConsole
from jarvis_assistant.ui.settings import SettingsDialog
from jarvis_assistant.ui.sidebar import CompactSidebar
from jarvis_assistant.wake_word import SherpaWakeBackend, WakeWordListener


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


class NoopWakeWord:
    running = False

    def start(self, callback: Callable[[], None]) -> None:
        del callback

    def stop(self) -> None:
        return


class MemoryCredentialStore:
    def __init__(self) -> None:
        self._key: str | None = None

    def get_openai_key(self) -> str | None:
        return self._key

    def set_openai_key(self, value: str | None) -> None:
        self._key = value or None


class MobileServer(Protocol):
    def start(self) -> None: ...

    def request_stop(self) -> None: ...

    def stop_and_join(self, timeout: float | None = None) -> None: ...


@dataclass(frozen=True)
class MobileBridgeComposition:
    controller: MobileServer
    pairing_session_owner: Any


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
        wake_listener: NoopWakeWord | WakeWordListener,
        mobile_server: MobileServer | None = None,
        pairing_session_owner: Any | None = None,
        pairing_code_callback: Callable[[], None] | None = None,
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
        self.wake_listener = wake_listener
        self.mobile_server = mobile_server
        self.pairing_session_owner = pairing_session_owner
        self._pairing_code_callback = pairing_code_callback
        self._pairing_dialog: Any | None = None
        self.wake_bridge = HotkeyBridge()
        self.sidebar = CompactSidebar()
        self.console = TaskConsole()
        self.capsule = VoiceCapsule()
        self.settings_dialog = SettingsDialog()
        self.tray = QSystemTrayIcon()
        self.paused = False
        self.closed = False
        self._shutting_down = False
        self._tasks: set[WorkerTask] = set()
        self._pending_kinds: dict[str, EventKind] = {}

        self._configure_tray()
        self._place_windows()
        self._connect_signals()

    def _configure_tray(self) -> None:
        icon = QApplication.windowIcon()
        if icon.isNull():
            icon = QApplication.style().standardIcon(QStyle.StandardPixmap.SP_ComputerIcon)
        self.tray.setIcon(icon)
        menu = QMenu()
        actions = (
            ("打开控制台", self.console.show),
            ("开始说话", self.toggle_recording),
            ("常驻唤醒", self.toggle_wake_word),
            ("暂停助手", self.toggle_pause),
            ("显示 iPhone 配对码", self.show_pairing_code),
            ("停止手机连接", self.stop_mobile_connection),
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
        self.sidebar.set_position_locked(settings.sidebar_locked)
        self.console.set_position_locked(settings.console_locked)
        for window in (self.sidebar, self.console, self.capsule):
            window.set_always_on_top(settings.always_on_top)
            window.set_click_through(settings.click_through)
        self.settings_dialog.always_on_top.setChecked(settings.always_on_top)
        self.settings_dialog.click_through.setChecked(settings.click_through)

    def _connect_signals(self) -> None:
        self.sidebar.expand_requested.connect(self.console.show)
        self.console.request_submitted.connect(self.submit_text)
        self.console.confirmation_answered.connect(self.answer_confirmation)
        self.bridge.activated.connect(self.toggle_recording)
        self.wake_bridge.activated.connect(self._wake_detected)
        self.settings_dialog.settings_saved.connect(self.save_settings)

    @Slot()
    def toggle_pause(self) -> None:
        self.paused = not self.paused
        self.sidebar.set_status("助手已暂停" if self.paused else "准备就绪")

    @Slot()
    def show_pairing_code(self) -> None:
        owner = self.pairing_session_owner
        if owner is not None:
            from jarvis_assistant.ui.pairing import PairingQrDialog

            session = owner.session_for_display()
            dialog = PairingQrDialog(session.qr_payload)
            self._pairing_dialog = dialog
            dialog.finished.connect(
                lambda _result: setattr(self, "_pairing_dialog", None)
                if self._pairing_dialog is dialog
                else None
            )
            dialog.show()
            self.sidebar.set_status("iPhone 配对码已显示。")
            return
        if self._pairing_code_callback is None:
            self.sidebar.set_status("尚未配置手机连接。")
            return
        self._pairing_code_callback()

    @Slot()
    def stop_mobile_connection(self) -> None:
        server = self.mobile_server
        if server is None:
            self.sidebar.set_status("手机连接已停止。")
            return

        def stopped(_result: object) -> None:
            if self.mobile_server is server:
                self.mobile_server = None
            self.sidebar.set_status("手机连接已停止。")

        self._run_background(
            server.stop_and_join,
            stopped,
        )

    @Slot()
    def toggle_wake_word(self) -> None:
        if self.wake_listener.running:
            self.wake_listener.stop()
            self.sidebar.set_status("常驻唤醒已关闭")
        else:
            self._resume_wake()

    @Slot()
    def _wake_detected(self) -> None:
        self.wake_listener.stop()
        self.toggle_recording()
        QTimer.singleShot(8000, self._finish_wake_recording)

    @Slot()
    def _finish_wake_recording(self) -> None:
        if self.recorder.recording:
            self.toggle_recording()

    @Slot(str)
    def submit_text(self, text: str) -> None:
        if self.paused:
            self.sidebar.set_status("助手已暂停")
            return
        normalized = "".join(text.strip().casefold().split()).rstrip("。.!！")
        if normalized in {"确认发送", "允许发送"}:
            pending_wechat = [
                action_id
                for action_id, kind in self._pending_kinds.items()
                if kind is EventKind.CONFIRMATION_REQUIRED
                and self.orchestrator.pending_action_is(action_id, "send_wechat_message")
            ]
            if len(pending_wechat) == 1:
                self.answer_confirmation(pending_wechat[0], True)
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
                if self.wake_listener.running:
                    self.wake_listener.stop()
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
        self._resume_wake()

    def _run_background(
        self,
        function: Callable[[], Any],
        on_success: Callable[[object], None],
        on_failure: Callable[[str], None] | None = None,
    ) -> None:
        task = WorkerTask(function)
        self._tasks.add(task)
        task.signals.succeeded.connect(on_success)
        task.signals.failed.connect(on_failure or self._show_error)
        task.signals.succeeded.connect(lambda _: self._tasks.discard(task))
        task.signals.failed.connect(lambda _: self._tasks.discard(task))
        QThreadPool.globalInstance().start(task)

    def _show_error(self, message: str) -> None:
        self.capsule.hide()
        self.console.append_message("assistant", message)
        self.console.show()
        self.sidebar.set_status(message)
        self._resume_wake()

    def _resume_wake(self) -> None:
        if self.paused or self.closed or self.recorder.recording or self.wake_listener.running:
            return
        try:
            self.wake_listener.start(self.wake_bridge.activated.emit)
            if self.wake_listener.running:
                self.sidebar.set_status("等待唤醒：你好，Jarvis")
        except Exception as error:
            self.sidebar.set_status(f"常驻唤醒不可用：{error}")

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
        if self.closed or self._shutting_down:
            return
        mobile_server = self.mobile_server
        if mobile_server is not None:
            self._shutting_down = True
            mobile_server.request_stop()
            self._run_background(
                mobile_server.stop_and_join,
                self._finish_shutdown,
                self._shutdown_failed,
            )
            return
        self._finish_shutdown(None)

    def _shutdown_failed(self, message: str) -> None:
        if self.closed:
            return
        self._shutting_down = False
        self._show_error(message)

    def _finish_shutdown(self, _result: object) -> None:
        if self.closed:
            return
        self.closed = True
        self._shutting_down = False
        self._persist_window_state()
        self.mobile_server = None
        self.hotkey.close()
        self.wake_listener.stop()
        if self.recorder.recording:
            with suppress(AudioError):
                self.recorder.stop()
        self.tray.hide()
        self.sidebar.close()
        self.console.close()
        self.capsule.close()
        self.settings_dialog.close()
        self.store.close()
        QApplication.quit()

    def _persist_window_state(self) -> None:
        settings = self.store.load_settings().model_copy(
            update={
                "sidebar_x": self.sidebar.x(),
                "sidebar_y": self.sidebar.y(),
                "console_x": self.console.x(),
                "console_y": self.console.y(),
                "capsule_x": self.capsule.x(),
                "capsule_y": self.capsule.y(),
                "sidebar_locked": self.sidebar.position_locked,
                "console_locked": self.console.position_locked,
            }
        )
        self.store.save_settings(Settings.model_validate(settings))


def build_application(
    *,
    data_dir: str | Path | None = None,
    test_mode: bool = False,
    mobile_server: MobileServer | None = None,
    pairing_code_callback: Callable[[], None] | None = None,
    bridge_host: str | None = None,
    mobile_bridge_factory: Callable[..., MobileBridgeComposition] | None = None,
) -> ApplicationRuntime:
    app = QApplication.instance()
    if app is None:
        raise RuntimeError("QApplication must be created before build_application")
    brand_icon = QIcon(str(_resource_path("assets", "jarvis-kobe.ico")))
    if not brand_icon.isNull():
        app.setWindowIcon(brand_icon)
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
    pairing_session_owner: Any | None = None
    configured_host = bridge_host
    if configured_host is None and not test_mode:
        configured_host = os.environ.get("JARVIS_BRIDGE_BIND_ADDRESS")
    if mobile_server is None and configured_host:
        composition_factory = mobile_bridge_factory or _compose_mobile_bridge
        composition = composition_factory(
            store=store,
            registry=registry,
            orchestrator=orchestrator,
            base_dir=base_dir,
            credentials=credentials,
            host=configured_host,
        )
        mobile_server = composition.controller
        pairing_session_owner = composition.pairing_session_owner
    runtime = ApplicationRuntime(
        store=store,
        credentials=credentials,
        orchestrator=orchestrator,
        local_provider=local,
        cloud_provider=cloud,
        hotkey=hotkey,
        bridge=bridge,
        recorder=AudioRecorder(
            SoundDeviceBackend(device=settings.microphone_name or "Lian II")
        ),
        transcriber=FasterWhisperTranscriber(
            "base", device="cpu", compute_type="int8"
        ),
        wake_listener=(
            NoopWakeWord()
            if test_mode
            else WakeWordListener(
                SherpaWakeBackend(
                    _resource_path(
                        "assets", "models", "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"
                    ),
                    _resource_path("assets", "models", "keywords.txt"),
                    device=settings.microphone_name or "Lian II",
                )
            )
        ),
        mobile_server=mobile_server,
        pairing_session_owner=pairing_session_owner,
        pairing_code_callback=pairing_code_callback,
    )
    if mobile_server is not None:
        mobile_server.start()
    if not test_mode:
        runtime._resume_wake()
    if settings.sidebar_visible:
        runtime.sidebar.show()
    return runtime


def _compose_mobile_bridge(
    *, store: SQLiteStore, registry: Any, orchestrator: Orchestrator, base_dir: Path,
    credentials: CredentialStore, host: str,
    controller_factory: Callable[..., MobileServer] | None = None,
) -> MobileBridgeComposition:
    """Compose the production LAN Bridge only for an explicitly selected address."""
    from jarvis_assistant.lan_bridge import compose_lan_bridge

    composition = compose_lan_bridge(
        store=store,
        registry=registry,
        base_dir=base_dir,
        credentials=credentials,
        host=host,
        chat_dispatcher=lambda text: _dispatch_orchestrator_chat(orchestrator, text),
        controller_factory=controller_factory,
    )
    return MobileBridgeComposition(
        controller=composition.controller,
        pairing_session_owner=composition.pairing_session_owner,
    )


async def _dispatch_orchestrator_chat(orchestrator: Orchestrator, text: str) -> str:
    """Planning-only remote chat: never invoke the desktop execution orchestrator."""
    allowed = {
        "open_application",
        "set_volume",
        "search_files",
        "open_file",
        "send_wechat_message",
    }
    catalog = [
        item for item in orchestrator._registry.schema_catalog() if item["name"] in allowed
    ]
    response = await orchestrator._local_provider.respond(
        ModelRequest(text=text, tool_catalog=catalog)
    )
    if response.proposal is not None:
        return "远程工具提案必须作为已签名的 Bridge 工具请求提交。"
    return response.text or ""


def _default_data_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("LOCALAPPDATA is unavailable")
    return Path(local_app_data) / "JarvisDesktopAssistant"


def _resource_path(*parts: str) -> Path:
    bundle_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    return bundle_root.joinpath(*parts)
