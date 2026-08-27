from __future__ import annotations

from enum import StrEnum
from uuid import uuid4

from pydantic import BaseModel, ConfigDict

from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.models import (
    ModelProvider,
    ModelRequest,
    ParsedModelResponse,
    ProviderRouter,
    ProviderUnavailable,
)
from jarvis_assistant.security import DecisionKind, SecurityPolicy
from jarvis_assistant.storage import SQLiteStore
from jarvis_assistant.tools import ToolRegistry


class EventKind(StrEnum):
    THINKING_LOCAL = "thinking_local"
    FALLBACK_AVAILABLE = "fallback_available"
    THINKING_CLOUD = "thinking_cloud"
    CONFIRMATION_REQUIRED = "confirmation_required"
    EXECUTING = "executing"
    COMPLETED = "completed"
    FAILED = "failed"
    REJECTED = "rejected"
    CANCELLED = "cancelled"


class OrchestratorEvent(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    kind: EventKind
    message: str
    action_id: str | None = None


class Orchestrator:
    def __init__(
        self,
        *,
        local_provider: ModelProvider,
        cloud_provider: ModelProvider | None,
        router: ProviderRouter,
        security: SecurityPolicy,
        registry: ToolRegistry,
        store: SQLiteStore,
    ) -> None:
        self._local_provider = local_provider
        self._cloud_provider = cloud_provider
        self._router = router
        self._security = security
        self._registry = registry
        self._store = store
        self._pending_actions: dict[str, ToolProposal] = {}
        self._pending_cloud: dict[str, ModelRequest] = {}

    async def submit(self, text: str) -> list[OrchestratorEvent]:
        request = ModelRequest(text=text, tool_catalog=self._registry.schema_catalog())
        events = [OrchestratorEvent(kind=EventKind.THINKING_LOCAL, message="正在本地处理…")]
        try:
            response = await self._local_provider.respond(request)
        except ProviderUnavailable:
            return events + self._offer_fallback(request, "本地模型不可用。")

        if self._router.fallback_eligible(response):
            return events + self._offer_fallback(request, "本地模型信心不足。")
        events.extend(self._handle_response(response))
        return events

    async def use_cloud(self, action_id: str | None) -> list[OrchestratorEvent]:
        if action_id is None or action_id not in self._pending_cloud:
            return [OrchestratorEvent(kind=EventKind.FAILED, message="云端请求已失效。")]
        request = self._pending_cloud.pop(action_id)
        if self._cloud_provider is None:
            return [OrchestratorEvent(kind=EventKind.FAILED, message="尚未配置云端模型。")]
        events = [OrchestratorEvent(kind=EventKind.THINKING_CLOUD, message="正在使用云端模型…")]
        try:
            response = await self._cloud_provider.respond(request)
        except ProviderUnavailable as error:
            return events + [OrchestratorEvent(kind=EventKind.FAILED, message=str(error))]
        events.extend(self._handle_response(response))
        return events

    async def confirm(self, action_id: str | None) -> list[OrchestratorEvent]:
        if action_id is None or action_id not in self._pending_actions:
            return [OrchestratorEvent(kind=EventKind.FAILED, message="待确认操作已失效。")]
        proposal = self._pending_actions.pop(action_id)
        decision = self._security.evaluate(proposal)
        if decision.kind is DecisionKind.REJECT:
            self._record_rejection(proposal, decision.code)
            return [OrchestratorEvent(kind=EventKind.REJECTED, message=decision.summary)]
        return self._execute(proposal)

    def cancel(self, action_id: str | None) -> OrchestratorEvent:
        if action_id:
            self._pending_actions.pop(action_id, None)
            self._pending_cloud.pop(action_id, None)
        return OrchestratorEvent(kind=EventKind.CANCELLED, message="操作已取消。")

    def _offer_fallback(self, request: ModelRequest, reason: str) -> list[OrchestratorEvent]:
        if self._cloud_provider is None:
            return [
                OrchestratorEvent(
                    kind=EventKind.FAILED,
                    message=f"{reason} 未配置 OpenAI，无法回退。",
                )
            ]
        action_id = str(uuid4())
        self._pending_cloud[action_id] = request
        return [
            OrchestratorEvent(
                kind=EventKind.FALLBACK_AVAILABLE,
                message=f"{reason} 是否切换到 OpenAI？",
                action_id=action_id,
            )
        ]

    def _handle_response(self, response: ParsedModelResponse) -> list[OrchestratorEvent]:
        if response.proposal is None:
            return [
                OrchestratorEvent(
                    kind=EventKind.COMPLETED,
                    message=response.text or "",
                )
            ]
        proposal = response.proposal
        decision = self._security.evaluate(proposal)
        if decision.kind is DecisionKind.REJECT:
            self._record_rejection(proposal, decision.code)
            return [OrchestratorEvent(kind=EventKind.REJECTED, message=decision.summary)]
        if decision.kind is DecisionKind.REQUIRE_CONFIRMATION:
            action_id = str(uuid4())
            self._pending_actions[action_id] = proposal
            return [
                OrchestratorEvent(
                    kind=EventKind.CONFIRMATION_REQUIRED,
                    message=decision.summary,
                    action_id=action_id,
                )
            ]
        return self._execute(proposal)

    def _execute(self, proposal: ToolProposal) -> list[OrchestratorEvent]:
        result = self._registry.execute(proposal)
        self._store.record_audit(
            proposal.tool_name,
            proposal.arguments,
            result.ok,
            result.message,
        )
        final_kind = EventKind.COMPLETED if result.ok else EventKind.FAILED
        return [
            OrchestratorEvent(kind=EventKind.EXECUTING, message="正在执行…"),
            OrchestratorEvent(kind=final_kind, message=result.message),
        ]

    def _record_rejection(self, proposal: ToolProposal, reason: str) -> None:
        self._store.record_audit(
            proposal.tool_name,
            proposal.arguments,
            False,
            reason,
        )
