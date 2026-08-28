from PySide6.QtCore import Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from jarvis_assistant.app import build_application
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

    assert events == ["start", "server_stopped", "sqlite_closed"]


def test_stop_mobile_connection_runs_off_qt_thread(qtbot, tmp_path) -> None:
    """Fails if the tray action blocks the UI while joining the Uvicorn thread."""
    calls: list[str] = []

    class RecordingMobileServer:
        def start(self) -> None:
            calls.append("start")

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

    assert events.index("server_stopped") < events.index("sqlite_closed")


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
