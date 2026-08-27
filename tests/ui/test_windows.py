from PySide6.QtCore import Qt

from jarvis_assistant.ui.capsule import VoiceCapsule
from jarvis_assistant.ui.console import TaskConsole
from jarvis_assistant.ui.sidebar import CompactSidebar


def test_console_is_compact_translucent_and_hidden_by_default(qtbot) -> None:
    console = TaskConsole()
    qtbot.addWidget(console)
    assert console.width() <= 420
    assert not console.isVisible()
    assert console.testAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
    assert console.windowFlags() & Qt.WindowType.FramelessWindowHint


def test_confirmation_emits_action_id(qtbot) -> None:
    console = TaskConsole()
    qtbot.addWidget(console)
    console.show_confirmation("action-1", "写入剪贴板（内容已隐藏）")
    with qtbot.waitSignal(console.confirmation_answered) as signal:
        qtbot.mouseClick(console.allow_button, Qt.MouseButton.LeftButton)
    assert signal.args == ["action-1", True]


def test_sidebar_is_small_and_emits_expand(qtbot) -> None:
    sidebar = CompactSidebar()
    qtbot.addWidget(sidebar)
    assert sidebar.width() <= 240
    with qtbot.waitSignal(sidebar.expand_requested):
        qtbot.mouseClick(sidebar.expand_button, Qt.MouseButton.LeftButton)


def test_windows_use_restored_light_layout_proportions(qtbot) -> None:
    sidebar = CompactSidebar()
    console = TaskConsole()
    capsule = VoiceCapsule()
    for widget in (sidebar, console, capsule):
        qtbot.addWidget(widget)

    assert 180 <= sidebar.width() <= 200
    assert sidebar.minimumHeight() >= 140
    assert 340 <= console.width() <= 365
    assert console.minimumHeight() >= 320
    assert 165 <= capsule.width() <= 190
    assert capsule.height() <= 48
    assert sidebar.open_latest_button.text() == "打开最新"


def test_glass_surface_paints_its_light_background(qtbot) -> None:
    sidebar = CompactSidebar()
    qtbot.addWidget(sidebar)
    sidebar.show()

    pixel = sidebar.grab().toImage().pixelColor(10, sidebar.height() // 2)
    assert pixel.alpha() >= 180
    assert pixel.red() > 200
    assert pixel.green() > 200
    assert pixel.blue() > 200


def test_capsule_shows_current_phase(qtbot) -> None:
    capsule = VoiceCapsule()
    qtbot.addWidget(capsule)
    assert not capsule.isVisible()
    capsule.show_phase("正在聆听…")
    assert capsule.phase_label.text() == "正在聆听…"
    assert capsule.isVisible()
