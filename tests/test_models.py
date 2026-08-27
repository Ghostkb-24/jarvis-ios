import json

import httpx
import pytest

from jarvis_assistant.models import (
    ModelRequest,
    OllamaProvider,
    OpenAIProvider,
    ProviderRouter,
    ProviderUnavailable,
    parse_model_response,
)


def test_parser_accepts_allowlisted_tool_envelope() -> None:
    parsed = parse_model_response(
        '{"type":"tool","tool_name":"open_application",'
        '"arguments":{"name":"notepad"},"confidence":0.9}'
    )
    assert parsed.proposal is not None
    assert parsed.proposal.tool_name == "open_application"


def test_parser_rejects_malformed_json() -> None:
    with pytest.raises(ValueError, match="invalid model response"):
        parse_model_response("not-json")


def test_router_uses_local_provider_first_and_flags_low_confidence() -> None:
    router = ProviderRouter(openai_available=True)
    assert router.initial_provider() == "ollama"
    response = parse_model_response(
        '{"type":"answer","text":"不确定","confidence":0.2}'
    )
    assert router.fallback_eligible(response)


@pytest.mark.asyncio
async def test_ollama_provider_sends_schema_and_parses_response() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert request.url.path == "/api/chat"
        assert payload["stream"] is False
        assert payload["format"]["type"] == "object"
        return httpx.Response(
            200,
            json={
                "message": {
                    "content": '{"type":"answer","text":"你好","confidence":0.95}'
                }
            },
        )

    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        base_url="http://127.0.0.1:11434",
    )
    provider = OllamaProvider(client=client, model="qwen2.5:3b")
    response = await provider.respond(ModelRequest(text="你好", tool_catalog=[]))
    assert response.text == "你好"
    await client.aclose()


@pytest.mark.asyncio
async def test_openai_provider_requires_key_and_sends_minimum_context() -> None:
    provider = OpenAIProvider(api_key=None)
    with pytest.raises(ProviderUnavailable):
        await provider.respond(ModelRequest(text="打开记事本", tool_catalog=[]))

    captured: dict[str, object] = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured.update(json.loads(request.content))
        return httpx.Response(
            200,
            json={
                "output": [
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": '{"type":"answer","text":"好的","confidence":0.9}',
                            }
                        ],
                    }
                ]
            },
        )

    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        base_url="https://api.openai.com/v1",
    )
    provider = OpenAIProvider(api_key="sk-test", client=client, model="gpt-5.4-mini")
    response = await provider.respond(ModelRequest(text="打开记事本", tool_catalog=[]))
    serialized = json.dumps(captured, ensure_ascii=False)
    assert response.text == "好的"
    assert "打开记事本" in serialized
    assert "clipboard" not in serialized
    assert captured["store"] is False
    await client.aclose()
