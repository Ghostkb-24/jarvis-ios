from __future__ import annotations

import json
from typing import Annotated, Any, Literal, Protocol

import httpx
from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError

from jarvis_assistant.domain import ToolProposal


class ProviderUnavailable(RuntimeError):
    pass


class ModelRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1)
    tool_catalog: list[dict[str, Any]]


class AnswerEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["answer"]
    text: str
    confidence: float = Field(ge=0.0, le=1.0)


class ToolEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["tool"]
    tool_name: str = Field(min_length=1)
    arguments: dict[str, Any]
    confidence: float = Field(ge=0.0, le=1.0)


ResponseEnvelope = Annotated[AnswerEnvelope | ToolEnvelope, Field(discriminator="type")]
_RESPONSE_ADAPTER = TypeAdapter(ResponseEnvelope)


class ParsedModelResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    text: str | None = None
    proposal: ToolProposal | None = None
    confidence: float


def parse_model_response(text: str) -> ParsedModelResponse:
    try:
        envelope = _RESPONSE_ADAPTER.validate_json(text)
    except ValidationError as error:
        raise ValueError("invalid model response") from error
    if isinstance(envelope, AnswerEnvelope):
        return ParsedModelResponse(text=envelope.text, confidence=envelope.confidence)
    return ParsedModelResponse(
        proposal=ToolProposal(
            tool_name=envelope.tool_name,
            arguments=envelope.arguments,
            confidence=envelope.confidence,
        ),
        confidence=envelope.confidence,
    )


class ModelProvider(Protocol):
    async def respond(self, request: ModelRequest) -> ParsedModelResponse: ...


class OllamaProvider:
    name = "ollama"

    def __init__(
        self,
        *,
        client: httpx.AsyncClient | None = None,
        base_url: str = "http://127.0.0.1:11434",
        model: str = "qwen2.5:3b",
    ) -> None:
        self._client = client or httpx.AsyncClient(base_url=base_url, timeout=90.0)
        self._owns_client = client is None
        self._model = model

    async def respond(self, request: ModelRequest) -> ParsedModelResponse:
        schema = _response_schema()
        prompt = _build_prompt(request, schema)
        payload = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            "format": schema,
            "options": {"temperature": 0},
        }
        try:
            response = await self._client.post("/api/chat", json=payload)
            response.raise_for_status()
            content = response.json()["message"]["content"]
            return parse_model_response(content)
        except (httpx.HTTPError, KeyError, TypeError, json.JSONDecodeError) as error:
            raise ProviderUnavailable("Ollama 暂时不可用。") from error

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


class OpenAIProvider:
    name = "openai"

    def __init__(
        self,
        *,
        api_key: str | None,
        client: httpx.AsyncClient | None = None,
        model: str = "gpt-5.4-mini",
    ) -> None:
        self._api_key = api_key
        self._client = client or httpx.AsyncClient(
            base_url="https://api.openai.com/v1",
            timeout=90.0,
        )
        self._owns_client = client is None
        self._model = model

    async def respond(self, request: ModelRequest) -> ParsedModelResponse:
        if not self._api_key:
            raise ProviderUnavailable("尚未配置 OpenAI API Key。")
        schema = _response_schema()
        payload = {
            "model": self._model,
            "instructions": _system_instructions(request.tool_catalog),
            "input": request.text,
            "store": False,
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "assistant_response",
                    "strict": True,
                    "schema": schema,
                }
            },
        }
        try:
            response = await self._client.post(
                "/responses",
                json=payload,
                headers={"Authorization": f"Bearer {self._api_key}"},
            )
            response.raise_for_status()
            content = _extract_openai_text(response.json())
            return parse_model_response(content)
        except (httpx.HTTPError, KeyError, TypeError, json.JSONDecodeError) as error:
            raise ProviderUnavailable("OpenAI 暂时不可用。") from error

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


class ProviderRouter:
    def __init__(self, *, openai_available: bool, confidence_threshold: float = 0.55) -> None:
        self.openai_available = openai_available
        self.confidence_threshold = confidence_threshold

    def initial_provider(self) -> str:
        return "ollama"

    def fallback_eligible(self, response: ParsedModelResponse | None) -> bool:
        return self.openai_available and (
            response is None or response.confidence < self.confidence_threshold
        )


def _build_prompt(request: ModelRequest, schema: dict[str, Any]) -> str:
    return (
        "你是 Windows 桌面助手。只输出符合 JSON Schema 的对象。"
        "只有当用户明确要求执行动作时才选择工具；否则直接回答。\n"
        "打开已安装的应用（例如微信）必须使用 open_application，不能使用 open_website。\n"
        "用户要求给微信联系人发送消息时必须使用 send_wechat_message。\n"
        f"可用工具：{json.dumps(request.tool_catalog, ensure_ascii=False)}\n"
        f"响应 Schema：{json.dumps(schema, ensure_ascii=False)}\n"
        f"用户请求：{request.text}"
    )


def _response_schema() -> dict[str, Any]:
    schema = _RESPONSE_ADAPTER.json_schema()
    schema.setdefault("type", "object")
    return schema


def _system_instructions(tool_catalog: list[dict[str, Any]]) -> str:
    return (
        "你是 Windows 桌面助手。只返回指定结构。只有用户明确要求执行动作时才选择工具。"
        "打开已安装的应用（例如微信）必须使用 open_application，不能使用 open_website。"
        "用户要求给微信联系人发送消息时必须使用 send_wechat_message。"
        "不得创造未列出的工具。可用工具："
        + json.dumps(tool_catalog, ensure_ascii=False)
    )


def _extract_openai_text(payload: dict[str, Any]) -> str:
    for item in payload.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text":
                return str(content["text"])
    raise KeyError("output_text")
