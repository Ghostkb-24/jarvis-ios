from pathlib import Path

import pytest

from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.tools import ToolRegistry, WindowsVolumeAdapter, default_registry


class MemoryClipboard:
    def __init__(self) -> None:
        self.value = ""

    def read(self) -> str:
        return self.value

    def write(self, text: str) -> None:
        self.value = text


class MemoryVolume:
    def __init__(self) -> None:
        self.value = 30

    def get_volume(self) -> int:
        return self.value

    def set_volume(self, percent: int) -> None:
        self.value = percent


def test_registry_rejects_unknown_tool() -> None:
    registry = ToolRegistry()
    with pytest.raises(KeyError):
        registry.execute(ToolProposal(tool_name="run_shell", arguments={}))


def test_open_website_rejects_non_http_scheme() -> None:
    registry = default_registry()
    result = registry.execute(
        ToolProposal(tool_name="open_website", arguments={"url": "file:///C:/Windows/win.ini"})
    )
    assert not result.ok
    assert result.code == "invalid_arguments"


def test_search_files_stays_inside_allowed_root_and_caps_results(tmp_path) -> None:
    allowed = tmp_path / "allowed"
    allowed.mkdir()
    for index in range(25):
        (allowed / f"report-{index}.txt").write_text("test", encoding="utf-8")
    registry = default_registry(allowed_search_roots=[allowed])

    result = registry.execute(
        ToolProposal(
            tool_name="search_files",
            arguments={"query": "report", "root": str(allowed), "limit": 50},
        )
    )

    assert result.ok
    assert len(result.data["paths"]) == 20
    assert all(Path(path).is_relative_to(allowed) for path in result.data["paths"])


def test_search_files_rejects_root_escape(tmp_path) -> None:
    allowed = tmp_path / "allowed"
    outside = tmp_path / "outside"
    allowed.mkdir()
    outside.mkdir()
    registry = default_registry(allowed_search_roots=[allowed])

    result = registry.execute(
        ToolProposal(
            tool_name="search_files",
            arguments={"query": "anything", "root": str(outside)},
        )
    )

    assert not result.ok
    assert result.code == "root_not_allowed"


def test_clipboard_and_volume_use_injected_adapters() -> None:
    clipboard = MemoryClipboard()
    volume = MemoryVolume()
    registry = default_registry(clipboard=clipboard, volume=volume)

    write_result = registry.execute(
        ToolProposal(
            tool_name="clipboard",
            arguments={"operation": "write", "text": "hello"},
        )
    )
    volume_result = registry.execute(
        ToolProposal(tool_name="set_volume", arguments={"percent": 55})
    )

    assert write_result.ok and clipboard.value == "hello"
    assert volume_result.ok and volume.value == 55


def test_volume_rejects_out_of_range_value() -> None:
    registry = default_registry(volume=MemoryVolume())
    result = registry.execute(ToolProposal(tool_name="set_volume", arguments={"percent": 101}))
    assert not result.ok
    assert result.code == "invalid_arguments"


class FakeEndpoint:
    def __init__(self) -> None:
        self.scalar = 0.42

    def GetMasterVolumeLevelScalar(self) -> float:
        return self.scalar

    def SetMasterVolumeLevelScalar(self, scalar: float, context) -> None:
        self.scalar = scalar


def test_windows_volume_adapter_converts_percent_and_scalar() -> None:
    endpoint = FakeEndpoint()
    adapter = WindowsVolumeAdapter(endpoint=endpoint)
    assert adapter.get_volume() == 42
    adapter.set_volume(65)
    assert endpoint.scalar == pytest.approx(0.65)


def test_windows_volume_adapter_casts_activated_com_pointer(monkeypatch) -> None:
    import comtypes
    from pycaw.pycaw import AudioUtilities

    endpoint = FakeEndpoint()
    raw_pointer = object()

    class FakeDevice:
        def Activate(self, interface_id, context, activation_params):
            return raw_pointer

    monkeypatch.setattr(AudioUtilities, "GetSpeakers", staticmethod(FakeDevice))
    monkeypatch.setattr(
        comtypes,
        "cast",
        lambda pointer, interface_type: endpoint if pointer is raw_pointer else None,
    )

    assert WindowsVolumeAdapter().get_volume() == 42
