from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from jarvis_assistant.app import build_application
from jarvis_assistant.orchestrator import EventKind, OrchestratorEvent


def test_runtime_registers_expected_tray_actions(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    labels = [action.text() for action in runtime.tray.contextMenu().actions()]
    assert labels == ["打开控制台", "开始说话", "暂停助手", "设置", "退出"]
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


def test_window_positions_persist_across_runtime_restart(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    runtime.sidebar.move(111, 122)
    runtime.console.move(333, 144)
    runtime.shutdown()

    restored = build_application(data_dir=tmp_path, test_mode=True)
    assert (restored.sidebar.x(), restored.sidebar.y()) == (111, 122)
    assert (restored.console.x(), restored.console.y()) == (333, 144)
    restored.shutdown()
