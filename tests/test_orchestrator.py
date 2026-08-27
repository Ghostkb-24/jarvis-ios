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


def build_orchestrator(tmp_path, local_response, cloud_response=None):
    clipboard = MemoryClipboard()
    registry = default_registry(clipboard=clipboard)
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
