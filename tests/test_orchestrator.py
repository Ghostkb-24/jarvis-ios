import pytest

from jarvis_assistant.models import ParsedModelResponse, ProviderRouter
from jarvis_assistant.orchestrator import EventKind, Orchestrator
from jarvis_assistant.security import SecurityPolicy
from jarvis_assistant.storage import SQLiteStore
from jarvis_assistant.tools import default_registry


class FakeProvider:
    def __init__(self, response: ParsedModelResponse) -> None:
        self.response = response
        self.requests = []

    async def respond(self, request):
        self.requests.append(request)
        return self.response


class MemoryClipboard:
    def __init__(self) -> None:
        self.value = ""

    def read(self) -> str:
        return self.value

    def write(self, text: str) -> None:
        self.value = text


def build_orchestrator(
    tmp_path,
    local_response,
    cloud_response=None,
    process_launcher=None,
    wechat_sender=None,
):
    clipboard = MemoryClipboard()
    registry = default_registry(
        clipboard=clipboard,
        process_launcher=process_launcher,
        wechat_sender=wechat_sender,
    )
    store = SQLiteStore.open(tmp_path / "state.db")
    local = FakeProvider(local_response)
    cloud = FakeProvider(cloud_response) if cloud_response else None
    orchestrator = Orchestrator(
        local_provider=local,
        cloud_provider=cloud,
        router=ProviderRouter(openai_available=cloud is not None),
        security=SecurityPolicy(registry),
        registry=registry,
        store=store,
    )
    return orchestrator, clipboard, store, local, cloud


@pytest.mark.asyncio
async def test_explicit_open_wechat_command_bypasses_web_routing(tmp_path) -> None:
    launched: list[list[str]] = []
    response = ParsedModelResponse(text="不应调用模型", confidence=0.9)
    orchestrator, _, store, local, _ = build_orchestrator(
        tmp_path,
        response,
        process_launcher=lambda command: launched.append(list(command)),
    )

    events = await orchestrator.submit("打开微信")

    assert events[-1].kind is EventKind.COMPLETED
    assert launched == [[r"C:\Program Files\Tencent\Weixin\Weixin.exe"]]
    assert local.requests == []
    store.close()


@pytest.mark.asyncio
async def test_medium_risk_action_waits_for_confirmation(tmp_path) -> None:
    response = ParsedModelResponse.model_validate(
        {
            "proposal": {
                "tool_name": "clipboard",
                "arguments": {"operation": "write", "text": "hello"},
                "confidence": 0.9,
            },
            "confidence": 0.9,
        }
    )
    orchestrator, clipboard, store, _, _ = build_orchestrator(tmp_path, response)

    events = await orchestrator.submit("把 hello 放到剪贴板")

    assert events[-1].kind is EventKind.CONFIRMATION_REQUIRED
    assert clipboard.value == ""
    confirmed = await orchestrator.confirm(events[-1].action_id)
    assert confirmed[-1].kind is EventKind.COMPLETED
    assert clipboard.value == "hello"
    store.close()


@pytest.mark.asyncio
async def test_explicit_spoken_wechat_message_waits_for_confirmation_then_sends(tmp_path) -> None:
    sent: list[tuple[str, str]] = []
    response = ParsedModelResponse(text="不应调用模型", confidence=0.9)
    orchestrator, _, store, local, _ = build_orchestrator(
        tmp_path,
        response,
        wechat_sender=lambda contact, message: sent.append((contact, message)) or True,
    )

    events = await orchestrator.submit("用微信给 Ghost（小号）发送 今晚八点见")

    assert events[-1].kind is EventKind.CONFIRMATION_REQUIRED
    assert "Ghost（小号）" in events[-1].message
    assert "今晚八点见" in events[-1].message
    assert sent == []
    assert local.requests == []

    confirmed = await orchestrator.confirm(events[-1].action_id)
    assert confirmed[-1].kind is EventKind.COMPLETED
    assert sent == [("Ghost（小号）", "今晚八点见")]
    store.close()


@pytest.mark.asyncio
async def test_invalid_tool_never_executes(tmp_path) -> None:
    response = ParsedModelResponse.model_validate(
        {
            "proposal": {"tool_name": "delete_file", "arguments": {}, "confidence": 0.9},
            "confidence": 0.9,
        }
    )
    orchestrator, _, store, _, _ = build_orchestrator(tmp_path, response)

    events = await orchestrator.submit("删除文件")

    assert events[-1].kind is EventKind.REJECTED
    assert store.list_audit(1)[0].tool_name == "delete_file"
    store.close()


@pytest.mark.asyncio
async def test_low_confidence_requires_disclosed_cloud_fallback(tmp_path) -> None:
    local_response = ParsedModelResponse(text="不确定", confidence=0.2)
    cloud_response = ParsedModelResponse(text="云端回答", confidence=0.9)
    orchestrator, _, store, _, cloud = build_orchestrator(
        tmp_path, local_response, cloud_response
    )

    events = await orchestrator.submit("复杂任务")
    assert events[-1].kind is EventKind.FALLBACK_AVAILABLE
    assert cloud.requests == []

    cloud_events = await orchestrator.use_cloud(events[-1].action_id)
    assert cloud_events[-1].kind is EventKind.COMPLETED
    assert cloud_events[-1].message == "云端回答"
    store.close()


@pytest.mark.asyncio
async def test_cancel_removes_pending_action(tmp_path) -> None:
    response = ParsedModelResponse.model_validate(
        {
            "proposal": {
                "tool_name": "clipboard",
                "arguments": {"operation": "write", "text": "hello"},
                "confidence": 0.9,
            },
            "confidence": 0.9,
        }
    )
    orchestrator, clipboard, store, _, _ = build_orchestrator(tmp_path, response)
    events = await orchestrator.submit("写入剪贴板")

    cancelled = orchestrator.cancel(events[-1].action_id)

    assert cancelled.kind is EventKind.CANCELLED
    assert clipboard.value == ""
    store.close()
