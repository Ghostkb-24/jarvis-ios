from jarvis_assistant.app import build_application
from jarvis_assistant.orchestrator import EventKind, OrchestratorEvent


def test_runtime_registers_expected_tray_actions(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    labels = [action.text() for action in runtime.tray.contextMenu().actions()]
    assert labels == ["打开控制台", "开始说话", "暂停助手", "设置", "退出"]
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
