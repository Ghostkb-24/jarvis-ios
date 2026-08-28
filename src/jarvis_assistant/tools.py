from __future__ import annotations

import os
import subprocess
import time
import webbrowser
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlparse

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from jarvis_assistant.domain import RiskLevel, ToolProposal, ToolResult


class ToolInput(BaseModel):
    model_config = ConfigDict(extra="forbid")


class OpenApplicationInput(ToolInput):
    name: str

    @field_validator("name")
    @classmethod
    def normalize_name(cls, value: str) -> str:
        return value.strip().casefold()


class OpenWebsiteInput(ToolInput):
    url: str

    @field_validator("url")
    @classmethod
    def require_http(cls, value: str) -> str:
        parsed = urlparse(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("only http and https URLs are allowed")
        return value


class SearchFilesInput(ToolInput):
    query: str = Field(min_length=1)
    root: Path | None = None
    limit: int = Field(default=20, ge=1, le=100)


class OpenFileInput(ToolInput):
    path: Path


class ClipboardInput(ToolInput):
    operation: str
    text: str | None = None

    @field_validator("operation")
    @classmethod
    def require_operation(cls, value: str) -> str:
        normalized = value.strip().casefold()
        if normalized not in {"read", "write"}:
            raise ValueError("operation must be read or write")
        return normalized


class SetVolumeInput(ToolInput):
    percent: int = Field(ge=0, le=100)


class WechatMessageInput(ToolInput):
    contact: str = Field(min_length=1, max_length=100)
    message: str = Field(min_length=1, max_length=2000)

    @field_validator("contact", "message")
    @classmethod
    def strip_text(cls, value: str) -> str:
        return value.strip()


class ClipboardAdapter(Protocol):
    def read(self) -> str: ...

    def write(self, text: str) -> None: ...


class VolumeAdapter(Protocol):
    def get_volume(self) -> int: ...

    def set_volume(self, percent: int) -> None: ...


ToolHandler = Callable[[ToolInput], ToolResult]


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    input_model: type[ToolInput]
    risk: RiskLevel
    handler: ToolHandler


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, ToolSpec] = {}

    def register(self, spec: ToolSpec) -> None:
        if spec.name in self._tools:
            raise ValueError(f"tool already registered: {spec.name}")
        self._tools[spec.name] = spec

    def get(self, name: str) -> ToolSpec:
        return self._tools[name]

    def schema_catalog(self) -> list[dict[str, Any]]:
        return [
            {
                "name": spec.name,
                "description": spec.description,
                "risk": spec.risk.name.lower(),
                "arguments": spec.input_model.model_json_schema(),
            }
            for spec in self._tools.values()
        ]

    def validate(self, proposal: ToolProposal) -> ToolInput:
        spec = self.get(proposal.tool_name)
        return spec.input_model.model_validate(proposal.arguments)

    def execute(self, proposal: ToolProposal) -> ToolResult:
        spec = self.get(proposal.tool_name)
        try:
            arguments = self.validate(proposal)
        except ValidationError as error:
            return ToolResult(
                ok=False,
                code="invalid_arguments",
                message="工具参数无效。",
                data={"errors": error.errors(include_url=False)},
            )
        try:
            return spec.handler(arguments)
        except OSError as error:
            return ToolResult(ok=False, code="operation_failed", message=str(error))


class UnavailableClipboard:
    def read(self) -> str:
        raise OSError("clipboard adapter is not configured")

    def write(self, text: str) -> None:
        raise OSError("clipboard adapter is not configured")


class UnavailableVolume:
    def get_volume(self) -> int:
        raise OSError("volume adapter is not configured")

    def set_volume(self, percent: int) -> None:
        raise OSError("volume adapter is not configured")


class WindowsVolumeAdapter:
    def __init__(self, endpoint: Any | None = None) -> None:
        self._endpoint = endpoint

    def _get_endpoint(self) -> Any:
        if self._endpoint is not None:
            return self._endpoint
        try:
            from ctypes import POINTER

            from comtypes import CLSCTX_ALL, cast
            from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
        except ImportError as error:
            raise OSError("Windows Core Audio adapter is unavailable") from error
        device = AudioUtilities.GetSpeakers()
        endpoint = getattr(device, "EndpointVolume", None)
        if endpoint is None:
            raw_endpoint = device.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)
            endpoint = cast(raw_endpoint, POINTER(IAudioEndpointVolume))
        self._endpoint = endpoint
        return endpoint

    def get_volume(self) -> int:
        scalar = float(self._get_endpoint().GetMasterVolumeLevelScalar())
        return round(scalar * 100)

    def set_volume(self, percent: int) -> None:
        self._get_endpoint().SetMasterVolumeLevelScalar(percent / 100, None)


def default_registry(
    *,
    allowed_search_roots: Sequence[Path] = (),
    clipboard: ClipboardAdapter | None = None,
    volume: VolumeAdapter | None = None,
    process_launcher: Callable[[Sequence[str]], Any] | None = None,
    file_launcher: Callable[[str], Any] | None = None,
    browser_opener: Callable[[str], Any] | None = None,
    application_activator: Callable[[str], bool] | None = None,
    wechat_sender: Callable[[str, str], bool] | None = None,
) -> ToolRegistry:
    registry = ToolRegistry()
    roots = tuple(path.resolve() for path in allowed_search_roots)
    clipboard_adapter = clipboard or UnavailableClipboard()
    volume_adapter = volume or (WindowsVolumeAdapter() if os.name == "nt" else UnavailableVolume())
    launch_process = process_launcher or _launch_process
    launch_file = file_launcher or os.startfile
    open_browser = browser_opener or webbrowser.open
    activate_application = application_activator or _activate_existing_application
    send_wechat = wechat_sender or _send_wechat_message

    application_commands = {
        "notepad": ["notepad.exe"],
        "记事本": ["notepad.exe"],
        "calculator": ["calc.exe"],
        "计算器": ["calc.exe"],
        "explorer": ["explorer.exe"],
        "文件资源管理器": ["explorer.exe"],
        "settings": ["cmd.exe", "/c", "start", "", "ms-settings:"],
        "设置": ["cmd.exe", "/c", "start", "", "ms-settings:"],
        "wechat": [r"C:\Program Files\Tencent\Weixin\Weixin.exe"],
        "weixin": [r"C:\Program Files\Tencent\Weixin\Weixin.exe"],
        "微信": [r"C:\Program Files\Tencent\Weixin\Weixin.exe"],
    }
    application_processes = {
        "notepad": "Notepad.exe",
        "记事本": "Notepad.exe",
        "calculator": "CalculatorApp.exe",
        "计算器": "CalculatorApp.exe",
        "explorer": "explorer.exe",
        "文件资源管理器": "explorer.exe",
        "settings": "SystemSettings.exe",
        "设置": "SystemSettings.exe",
        "wechat": "Weixin.exe",
        "weixin": "Weixin.exe",
        "微信": "Weixin.exe",
    }

    def open_application(value: ToolInput) -> ToolResult:
        arguments = _as(value, OpenApplicationInput)
        command = application_commands.get(arguments.name)
        if command is None:
            return ToolResult(
                ok=False,
                code="application_not_allowed",
                message="应用不在白名单中。",
            )
        process_name = application_processes.get(arguments.name)
        if process_name and activate_application(process_name):
            return ToolResult(ok=True, code="activated", message="已切换到正在运行的应用。")
        launch_process(command)
        return ToolResult(ok=True, code="opened", message="应用已打开。")

    def open_website(value: ToolInput) -> ToolResult:
        arguments = _as(value, OpenWebsiteInput)
        if not open_browser(arguments.url):
            return ToolResult(ok=False, code="operation_failed", message="浏览器未接受请求。")
        return ToolResult(ok=True, code="opened", message="网页已打开。")

    def send_wechat_message(value: ToolInput) -> ToolResult:
        arguments = _as(value, WechatMessageInput)
        if not send_wechat(arguments.contact, arguments.message):
            return ToolResult(
                ok=False,
                code="operation_failed",
                message="未能完成微信发送，请确认微信已登录且联系人名称准确。",
            )
        return ToolResult(ok=True, code="sent", message="微信消息已发送。")

    def search_files(value: ToolInput) -> ToolResult:
        arguments = _as(value, SearchFilesInput)
        if not roots:
            return ToolResult(ok=False, code="no_search_roots", message="尚未配置文件搜索目录。")
        selected_root = (arguments.root or roots[0]).resolve()
        if not any(selected_root.is_relative_to(root) for root in roots):
            return ToolResult(ok=False, code="root_not_allowed", message="搜索目录不在允许范围内。")
        query = arguments.query.casefold()
        matches: list[str] = []
        result_limit = min(arguments.limit, 20)
        for path in selected_root.rglob("*"):
            if path.is_file() and query in path.name.casefold():
                matches.append(str(path))
                if len(matches) >= result_limit:
                    break
        return ToolResult(
            ok=True,
            code="search_complete",
            message=f"找到 {len(matches)} 个文件。",
            data={"paths": matches},
        )

    def open_file(value: ToolInput) -> ToolResult:
        arguments = _as(value, OpenFileInput)
        path = arguments.path.resolve()
        if not path.is_file():
            return ToolResult(ok=False, code="file_not_found", message="文件不存在。")
        if not roots:
            return ToolResult(
                ok=False,
                code="file_not_allowed",
                message="尚未配置允许打开的文件目录。",
            )
        if roots and not any(path.is_relative_to(root) for root in roots):
            return ToolResult(ok=False, code="file_not_allowed", message="文件不在允许范围内。")
        launch_file(str(path))
        return ToolResult(ok=True, code="opened", message="文件已打开。")

    def use_clipboard(value: ToolInput) -> ToolResult:
        arguments = _as(value, ClipboardInput)
        if arguments.operation == "read":
            return ToolResult(
                ok=True,
                code="clipboard_read",
                message="已读取剪贴板。",
                data={"text": clipboard_adapter.read()},
            )
        if arguments.text is None:
            return ToolResult(ok=False, code="invalid_arguments", message="写入时必须提供文本。")
        clipboard_adapter.write(arguments.text)
        return ToolResult(ok=True, code="clipboard_written", message="已写入剪贴板。")

    def set_volume(value: ToolInput) -> ToolResult:
        arguments = _as(value, SetVolumeInput)
        previous = volume_adapter.get_volume()
        volume_adapter.set_volume(arguments.percent)
        return ToolResult(
            ok=True,
            code="volume_set",
            message=f"音量已设置为 {arguments.percent}%。",
            data={"previous": previous, "current": arguments.percent},
        )

    for spec in (
        ToolSpec(
            "open_application",
            "打开白名单中的本地 Windows 应用（包括微信）；打开微信时不要使用网页工具",
            OpenApplicationInput,
            RiskLevel.LOW,
            open_application,
        ),
        ToolSpec(
            "open_website",
            "打开 HTTP 或 HTTPS 网页",
            OpenWebsiteInput,
            RiskLevel.LOW,
            open_website,
        ),
        ToolSpec(
            "send_wechat_message",
            "在微信中搜索指定联系人并发送消息；必须保留联系人和消息原文",
            WechatMessageInput,
            RiskLevel.MEDIUM,
            send_wechat_message,
        ),
        ToolSpec(
            "search_files",
            "在允许目录中搜索文件",
            SearchFilesInput,
            RiskLevel.LOW,
            search_files,
        ),
        ToolSpec("open_file", "打开允许目录中的现有文件", OpenFileInput, RiskLevel.LOW, open_file),
        ToolSpec("clipboard", "读取或写入剪贴板", ClipboardInput, RiskLevel.MEDIUM, use_clipboard),
        ToolSpec("set_volume", "设置系统输出音量", SetVolumeInput, RiskLevel.LOW, set_volume),
    ):
        registry.register(spec)
    return registry


def _activate_existing_application(process_name: str) -> bool:
    if os.name != "nt":
        return False
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    target = process_name.casefold()
    activated = False
    process_query_limited_information = 0x1000

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def visit_window(hwnd, lparam):
        nonlocal activated
        del lparam
        if not user32.IsWindowVisible(hwnd) or user32.GetWindowTextLengthW(hwnd) == 0:
            return True
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        handle = kernel32.OpenProcess(process_query_limited_information, False, pid.value)
        if not handle:
            return True
        try:
            size = wintypes.DWORD(32768)
            path = ctypes.create_unicode_buffer(size.value)
            if not kernel32.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(size)):
                return True
            if Path(path.value).name.casefold() != target:
                return True
            user32.ShowWindow(hwnd, 9)
            user32.BringWindowToTop(hwnd)
            user32.SetForegroundWindow(hwnd)
            activated = True
            return False
        finally:
            kernel32.CloseHandle(handle)

    user32.EnumWindows(visit_window, 0)
    return activated


def _send_wechat_message(contact: str, message: str) -> bool:
    if os.name != "nt" or not _activate_existing_application("Weixin.exe"):
        return False
    try:
        import win32clipboard
        from pynput.keyboard import Controller, Key
    except ImportError as error:
        raise OSError("微信自动化组件不可用。") from error

    keyboard = Controller()
    previous: str | None = None

    def set_clipboard(text: str) -> None:
        win32clipboard.OpenClipboard()
        try:
            win32clipboard.EmptyClipboard()
            win32clipboard.SetClipboardText(text, win32clipboard.CF_UNICODETEXT)
        finally:
            win32clipboard.CloseClipboard()

    def paste(text: str) -> None:
        set_clipboard(text)
        with keyboard.pressed(Key.ctrl):
            keyboard.press("v")
            keyboard.release("v")

    try:
        win32clipboard.OpenClipboard()
        try:
            if win32clipboard.IsClipboardFormatAvailable(win32clipboard.CF_UNICODETEXT):
                previous = win32clipboard.GetClipboardData(win32clipboard.CF_UNICODETEXT)
        finally:
            win32clipboard.CloseClipboard()

        time.sleep(0.4)
        with keyboard.pressed(Key.ctrl):
            keyboard.press("f")
            keyboard.release("f")
        time.sleep(0.5)
        paste(contact)
        time.sleep(1.0)
        keyboard.press(Key.enter)
        keyboard.release(Key.enter)
        time.sleep(0.8)
        paste(message)
        time.sleep(0.3)
        keyboard.press(Key.enter)
        keyboard.release(Key.enter)
        return True
    finally:
        if previous is not None:
            set_clipboard(previous)


def _as(value: ToolInput, expected: type[ToolInput]) -> Any:
    if not isinstance(value, expected):
        raise TypeError(f"expected {expected.__name__}")
    return value


def _launch_process(command: Sequence[str]) -> subprocess.Popen[bytes]:
    return subprocess.Popen(list(command), shell=False)
