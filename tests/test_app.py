import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from jarvis_assistant.app import (
    MobileBridgeComposition,
    _compose_mobile_bridge,
    _dispatch_orchestrator_chat,
    build_application,
)
from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.orchestrator import EventKind, OrchestratorEvent


def test_runtime_registers_expected_tray_actions(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    labels = [action.text() for action in runtime.tray.contextMenu().actions()]
    assert labels == [
        "打开控制台",
        "开始说话",
        "常驻唤醒",
        "暂停助手",
        "显示 iPhone 配对码",
        "停止手机连接",
        "设置",
        "退出",
    ]
    runtime.shutdown()


def test_runtime_uses_same_brand_icon_for_application_and_tray(qtbot, tmp_path) -> None:
    QApplication.setWindowIcon(QIcon())
    runtime = build_application(data_dir=tmp_path, test_mode=True)

    assert not QApplication.windowIcon().isNull()
    assert runtime.tray.icon().cacheKey() == QApplication.windowIcon().cacheKey()
    runtime.shutdown()


def test_sidebar_expands_console(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    qtbot.addWidget(runtime.sidebar)
    qtbot.addWidget(runtime.console)
    runtime.sidebar.expand_requested.emit()
    assert runtime.console.isVisible()
    runtime.shutdown()


def test_sidebar_uses_approved_dimensions(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    qtbot.addWidget(runtime.sidebar)

    assert runtime.sidebar.width() == 190
    assert runtime.sidebar.height() == 300
    assert runtime.sidebar.minimumHeight() == 300

    runtime.shutdown()


def test_runtime_uses_fast_cpu_transcriber(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    assert runtime.transcriber._model_name == "base"
    assert runtime.transcriber._device == "cpu"
    assert runtime.transcriber._compute_type == "int8"
    runtime.shutdown()


def test_window_lock_buttons_persist_across_restart(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.sidebar.lock_button.click()
    runtime.console.lock_button.click()
    assert runtime.sidebar.position_locked
    assert runtime.console.position_locked
    runtime.shutdown()

    restored = build_application(data_dir=tmp_path, test_mode=True)
    assert restored.sidebar.position_locked
    assert restored.console.position_locked
    restored.shutdown()


def test_pause_updates_runtime_and_sidebar(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.toggle_pause()
    assert runtime.paused
    assert runtime.sidebar.result_label.text() == "助手已暂停"
    runtime.shutdown()


def test_shutdown_closes_store_and_hotkey(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.shutdown()
    assert runtime.hotkey.closed
    assert runtime.closed


def test_mobile_server_stops_and_joins_before_sqlite_closes(qtbot, tmp_path) -> None:
    """Fails if shutdown closes persistence while the mobile server can still use it."""
    events: list[str] = []

    class RecordingMobileServer:
        def start(self) -> None:
            events.append("start")

        def request_stop(self) -> None:
            events.append("stop_requested")

        def stop_and_join(self, timeout: float | None = None) -> None:
            del timeout
            events.append("server_stopped")

    mobile_server = RecordingMobileServer()
    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        mobile_server=mobile_server,
    )
    close_store = runtime.store.close

    def record_close() -> None:
        events.append("sqlite_closed")
        close_store()

    runtime.store.close = record_close
    runtime.shutdown()

    qtbot.waitUntil(lambda: runtime.closed)
    assert events == ["start", "stop_requested", "server_stopped", "sqlite_closed"]


def test_production_composition_runtime_owns_started_controller_until_shutdown(
    qtbot,
    tmp_path,
) -> None:
    """Fails if production loses the exact controller or pairing-session owner it starts."""
    events: list[str] = []
    pairing_owner = object()

    class RecordingMobileServer:
        def start(self) -> None:
            events.append("start")

        def request_stop(self) -> None:
            events.append("stop_requested")

        def stop_and_join(self, timeout: float | None = None) -> None:
            del timeout
            events.append("server_stopped")

    controller = RecordingMobileServer()

    def compose_mobile_bridge(**_kwargs) -> MobileBridgeComposition:
        events.append("compose")
        return MobileBridgeComposition(
            controller=controller,
            pairing_session_owner=pairing_owner,
        )

    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        bridge_host="192.168.1.20",
        mobile_bridge_factory=compose_mobile_bridge,
    )
    close_store = runtime.store.close

    def record_close() -> None:
        events.append("sqlite_closed")
        close_store()

    runtime.store.close = record_close

    assert runtime.mobile_server is controller
    assert runtime.pairing_session_owner is pairing_owner
    assert events == ["compose", "start"]

    runtime.shutdown()
    qtbot.waitUntil(lambda: runtime.closed)

    assert events == [
        "compose",
        "start",
        "stop_requested",
        "server_stopped",
        "sqlite_closed",
    ]


def test_production_composition_leaves_no_private_key_file(tmp_path) -> None:
    """Fails if production keeps an ordinary bridge-key.pem after TLS is loaded."""
    from jarvis_assistant.storage import SQLiteStore
    from jarvis_assistant.tools import default_registry

    class MemoryBackend:
        def __init__(self) -> None:
            self.passwords: dict[tuple[str, str], str] = {}

        def get_password(self, service: str, username: str) -> str | None:
            return self.passwords.get((service, username))

        def set_password(self, service: str, username: str, value: str) -> None:
            self.passwords[(service, username)] = value

        def delete_password(self, service: str, username: str) -> None:
            self.passwords.pop((service, username), None)

    class Credentials:
        _backend = MemoryBackend()

    class MemoryVolume:
        def get_volume(self) -> int:
            return 20

        def set_volume(self, percent: int) -> None:
            del percent

    store = SQLiteStore.open(tmp_path / "state.db")
    try:
        composition = _compose_mobile_bridge(
            store=store,
            registry=default_registry(volume=MemoryVolume()),
            orchestrator=object(),
            base_dir=tmp_path,
            credentials=Credentials(),
            host="192.168.1.20",
        )

        assert composition.controller is not None
        assert not (tmp_path / "bridge-key.pem").exists()
        assert not list(tmp_path.glob(".jarvis-bridge-*.key"))
    finally:
        store.close()


def bridge_factory_with_controller(controller_factory):
    class MemoryBackend:
        def __init__(self) -> None:
            self.passwords: dict[tuple[str, str], str] = {}

        def get_password(self, service: str, username: str) -> str | None:
            return self.passwords.get((service, username))

        def set_password(self, service: str, username: str, value: str) -> None:
            self.passwords[(service, username)] = value

        def delete_password(self, service: str, username: str) -> None:
            self.passwords.pop((service, username), None)

    class Credentials:
        _backend = MemoryBackend()

    def compose(**kwargs):
        kwargs["credentials"] = Credentials()
        return _compose_mobile_bridge(
            **kwargs,
            controller_factory=controller_factory,
        )

    return compose


def test_tls_private_key_is_absent_when_controller_start_fails(qtbot, tmp_path) -> None:
    """Fails if a server-start exception can strand an ordinary private-key file."""
    class StartFailureController:
        def __init__(self, _app, *, host, ssl_context) -> None:
            assert host == "192.168.1.20"
            assert ssl_context is not None

        def start(self) -> None:
            assert not list(tmp_path.glob("*bridge*.key"))
            assert not (tmp_path / "bridge-key.pem").exists()
            raise RuntimeError("start failed")

        def request_stop(self) -> None:
            return

        def stop_and_join(self, timeout: float | None = None) -> None:
            del timeout

    with pytest.raises(RuntimeError, match="start failed"):
        build_application(
            data_dir=tmp_path,
            test_mode=True,
            bridge_host="192.168.1.20",
            mobile_bridge_factory=bridge_factory_with_controller(StartFailureController),
        )

    assert not list(tmp_path.glob("*bridge*.key"))
    assert not (tmp_path / "bridge-key.pem").exists()


def test_tls_private_key_is_absent_during_tray_stop(qtbot, tmp_path) -> None:
    """Fails if stopping a composed controller leaves reusable key material on disk."""
    events: list[str] = []

    class RecordingController:
        def __init__(self, _app, *, host, ssl_context) -> None:
            assert host == "192.168.1.20"
            assert ssl_context is not None

        def start(self) -> None:
            events.append("start")
            assert not list(tmp_path.glob("*bridge*.key"))

        def request_stop(self) -> None:
            events.append("stop_requested")

        def stop_and_join(self, timeout: float | None = None) -> None:
            del timeout
            assert not list(tmp_path.glob("*bridge*.key"))
            events.append("stopped")

    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        bridge_host="192.168.1.20",
        mobile_bridge_factory=bridge_factory_with_controller(RecordingController),
    )
    runtime.stop_mobile_connection()
    qtbot.waitUntil(lambda: runtime.mobile_server is None)

    assert events == ["start", "stopped"]
    assert not list(tmp_path.glob("*bridge*.key"))
    runtime.shutdown()


def test_tls_private_key_is_absent_during_application_shutdown(qtbot, tmp_path) -> None:
    """Fails if shutdown cleanup depends on retaining a plaintext private-key file."""
    events: list[str] = []

    class RecordingController:
        def __init__(self, _app, *, host, ssl_context) -> None:
            assert host == "192.168.1.20"
            assert ssl_context is not None

        def start(self) -> None:
            events.append("start")
            assert not list(tmp_path.glob("*bridge*.key"))

        def request_stop(self) -> None:
            events.append("stop_requested")

        def stop_and_join(self, timeout: float | None = None) -> None:
            del timeout
            assert not list(tmp_path.glob("*bridge*.key"))
            events.append("stopped")

    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        bridge_host="192.168.1.20",
        mobile_bridge_factory=bridge_factory_with_controller(RecordingController),
    )
    runtime.shutdown()
    qtbot.waitUntil(lambda: runtime.closed)

    assert events == ["start", "stop_requested", "stopped"]
    assert not list(tmp_path.glob("*bridge*.key"))


def test_pairing_action_shows_scannable_qr_without_plaintext_proof_leakage(
    qtbot,
    tmp_path,
    caplog,
) -> None:
    """Fails if pairing proof appears as text/status/log/audit instead of only in a QR."""
    from PySide6.QtWidgets import QLabel

    from jarvis_assistant.bridge.pairing import PairingSessionOwner
    from jarvis_assistant.ui.pairing import PairingQrDialog

    owner = PairingSessionOwner(
        bridge_id="bridge-01",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
    )
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.pairing_session_owner = owner

    runtime.show_pairing_code()

    session = owner.session_for_display()
    dialog = runtime._pairing_dialog
    assert isinstance(dialog, PairingQrDialog)
    qtbot.addWidget(dialog)
    pixmap = dialog.qr_label.pixmap()
    assert pixmap is not None and not pixmap.isNull()
    assert pixmap.width() >= 240 and pixmap.height() >= 240
    visible_text = " ".join(label.text() for label in dialog.findChildren(QLabel))
    assert session.proof not in visible_text
    assert session.proof not in runtime.sidebar.result_label.text()
    assert session.proof not in caplog.text
    assert all(
        session.proof not in event.arguments_summary
        and session.proof not in event.result_summary
        for event in runtime.store.list_audit()
    )

    dialog.close()
    assert owner.session_for_display() is session
    runtime.shutdown()


def test_stop_mobile_connection_runs_off_qt_thread(qtbot, tmp_path) -> None:
    """Fails if the tray action blocks the UI while joining the Uvicorn thread."""
    calls: list[str] = []

    class RecordingMobileServer:
        def start(self) -> None:
            calls.append("start")

        def request_stop(self) -> None:
            return

        def stop_and_join(self, timeout: float | None = None) -> None:
            del timeout
            calls.append("stop")

    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        mobile_server=RecordingMobileServer(),
    )
    runtime.stop_mobile_connection()

    qtbot.waitUntil(lambda: calls == ["start", "stop"])
    runtime.shutdown()


def test_shutdown_waits_for_an_inflight_mobile_stop_before_closing_sqlite(
    qtbot,
    tmp_path,
) -> None:
    """Fails if an asynchronous tray stop lets shutdown close SQLite too early."""
    from threading import Event, Lock

    events: list[str] = []
    first_stop_started = Event()
    release_first_stop = Event()
    call_lock = Lock()
    stop_calls = 0

    class RecordingMobileServer:
        def start(self) -> None:
            events.append("start")

        def request_stop(self) -> None:
            return

        def stop_and_join(self, timeout: float | None = None) -> None:
            nonlocal stop_calls
            del timeout
            with call_lock:
                stop_calls += 1
                call_number = stop_calls
            if call_number == 1:
                first_stop_started.set()
                assert release_first_stop.wait(timeout=2)
            else:
                events.append("server_stopped")

    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        mobile_server=RecordingMobileServer(),
    )
    close_store = runtime.store.close

    def record_close() -> None:
        events.append("sqlite_closed")
        close_store()

    runtime.store.close = record_close
    runtime.stop_mobile_connection()
    assert first_stop_started.wait(timeout=2)
    runtime.shutdown()
    release_first_stop.set()

    qtbot.waitUntil(lambda: runtime.closed)

    assert events.index("server_stopped") < events.index("sqlite_closed")


def test_shutdown_timeout_is_retryable_and_quits_only_after_sqlite_close(
    qtbot,
    tmp_path,
    monkeypatch,
) -> None:
    """Fails if a join timeout wedges shutdown, closes DB, or quits prematurely."""
    events: list[str] = []
    join_attempts = 0

    class RetryingMobileServer:
        def start(self) -> None:
            events.append("start")

        def request_stop(self) -> None:
            events.append("stop_requested")

        def stop_and_join(self, timeout: float | None = None) -> None:
            nonlocal join_attempts
            del timeout
            join_attempts += 1
            if join_attempts == 1:
                raise TimeoutError("join timed out")
            events.append("server_stopped")

    server = RetryingMobileServer()
    runtime = build_application(
        data_dir=tmp_path,
        test_mode=True,
        mobile_server=server,
    )
    close_store = runtime.store.close

    def record_close() -> None:
        events.append("sqlite_closed")
        close_store()

    runtime.store.close = record_close
    monkeypatch.setattr(QApplication, "quit", lambda: events.append("quit"))

    try:
        runtime.shutdown()

        assert not runtime.closed
        assert runtime.mobile_server is server
        qtbot.waitUntil(lambda: not runtime._shutting_down)

        assert "join timed out" in runtime.sidebar.result_label.text()
        assert runtime.store.load_settings() is not None
        assert "sqlite_closed" not in events
        assert "quit" not in events

        runtime.shutdown()
        qtbot.waitUntil(lambda: runtime.closed)

        assert join_attempts == 2
        assert runtime.mobile_server is None
        assert events[-3:] == ["server_stopped", "sqlite_closed", "quit"]
    finally:
        if not runtime.closed:
            runtime.mobile_server = None
            runtime._finish_shutdown(None)


def test_cloud_fallback_confirmation_calls_use_cloud(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    called = []

    async def use_cloud(action_id):
        called.append(action_id)
        return [OrchestratorEvent(kind=EventKind.COMPLETED, message="云端完成")]

    runtime.orchestrator.use_cloud = use_cloud
    runtime._handle_events(
        [
            OrchestratorEvent(
                kind=EventKind.FALLBACK_AVAILABLE,
                message="切换云端？",
                action_id="cloud-1",
            )
        ]
    )
    runtime.answer_confirmation("cloud-1", True)
    qtbot.waitUntil(lambda: called == ["cloud-1"])
    runtime.shutdown()


def test_settings_save_persists_key_and_preferences(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.settings_dialog.settings_saved.emit(
        {
            "ollama_model": "qwen2.5:3b",
            "openai_key": "sk-test",
            "always_on_top": False,
            "click_through": False,
        }
    )
    assert runtime.credentials.get_openai_key() == "sk-test"
    assert not runtime.store.load_settings().always_on_top
    runtime.shutdown()


def test_saved_always_on_top_preference_is_applied_after_restart(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.save_settings(
        {
            "ollama_model": "qwen2.5:3b",
            "openai_key": "",
            "always_on_top": True,
            "click_through": False,
        }
    )
    runtime.shutdown()

    restored = build_application(data_dir=tmp_path, test_mode=True)
    assert all(
        window.windowFlags() & Qt.WindowType.WindowStaysOnTopHint
        for window in (restored.sidebar, restored.console, restored.capsule)
    )
    restored.shutdown()


def test_window_positions_persist_across_runtime_restart(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.sidebar.move(111, 122)
    runtime.console.move(333, 144)
    runtime.shutdown()

    restored = build_application(data_dir=tmp_path, test_mode=True)
    assert (restored.sidebar.x(), restored.sidebar.y()) == (111, 122)
    assert (restored.console.x(), restored.console.y()) == (333, 144)
    restored.shutdown()


def test_voice_confirmation_sends_the_single_pending_wechat_action(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime._pending_kinds["wechat-1"] = EventKind.CONFIRMATION_REQUIRED
    runtime.orchestrator._pending_actions["wechat-1"] = ToolProposal(
        tool_name="send_wechat_message",
        arguments={"contact": "Ghost（小号）", "message": "今晚八点见"},
    )
    answered: list[tuple[str, bool]] = []
    runtime.answer_confirmation = lambda action_id, allowed: answered.append(
        (action_id, allowed)
    )

    runtime.submit_text("确认发送")

    assert answered == [("wechat-1", True)]
    runtime.shutdown()


def test_remote_chat_planning_never_calls_executing_orchestrator(qtbot, tmp_path) -> None:
    """Fails if a remote chat request reaches Orchestrator.submit and executes a tool."""
    runtime = build_application(data_dir=tmp_path, test_mode=True)

    async def forbidden_submit(_text):
        raise AssertionError("remote chat must not call Orchestrator.submit")

    class PlanningProvider:
        async def respond(self, request):
            assert {item["name"] for item in request.tool_catalog} == {
                "open_application", "set_volume", "search_files", "open_file", "send_wechat_message"
            }
            from jarvis_assistant.models import ParsedModelResponse
            return ParsedModelResponse(text="计划回答", confidence=1.0)

    runtime.orchestrator.submit = forbidden_submit
    runtime.orchestrator._local_provider = PlanningProvider()

    import asyncio
    assert asyncio.run(_dispatch_orchestrator_chat(runtime.orchestrator, "你好")) == "计划回答"
    runtime.shutdown()
