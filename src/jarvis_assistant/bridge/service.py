from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from jarvis_assistant.bridge.auth import AuthenticationError, verify_request
from jarvis_assistant.bridge.device_store import DeviceStore
from jarvis_assistant.bridge.idempotency import IdempotencyLedger, TaskRecord
from jarvis_assistant.bridge.pairing import PairedDevice, PairingSession
from jarvis_assistant.bridge.protocol import BridgeRequest, BridgeResponse, Risk, TaskState
from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.tools import ToolRegistry


class BridgeAuthenticationError(ValueError):
    pass


class BridgeAuthorizationError(ValueError):
    pass


class BridgeValidationError(ValueError):
    pass


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class _ToolPayload(_StrictModel):
    tool: str = Field(min_length=1)
    arguments: dict[str, Any]


class _TargetPayload(_StrictModel):
    target_request_id: str = Field(min_length=1)


class _OpenApplicationArguments(_StrictModel):
    name: str = Field(min_length=1, max_length=100)

    @field_validator("name")
    @classmethod
    def strip_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("application name must not be blank")
        return normalized


class _SetVolumeArguments(_StrictModel):
    percent: int = Field(ge=0, le=100)


class _SearchFilesArguments(_StrictModel):
    query: str = Field(min_length=1, max_length=200)
    root: Path | None = None
    limit: int = Field(default=20, ge=1, le=20)

    @field_validator("query")
    @classmethod
    def strip_query(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("query must not be blank")
        return normalized


class _OpenFileArguments(_StrictModel):
    path: Path

    @field_validator("path", mode="before")
    @classmethod
    def reject_blank_path(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            raise ValueError("path must not be blank")
        return value


class _WechatArguments(_StrictModel):
    contact: str = Field(min_length=1, max_length=100)
    message: str = Field(min_length=1, max_length=2000)

    @field_validator("contact", "message")
    @classmethod
    def strip_text(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("text must not be blank")
        return normalized


_REMOTE_ARGUMENT_MODELS: dict[str, type[_StrictModel]] = {
    "open_application": _OpenApplicationArguments,
    "set_volume": _SetVolumeArguments,
    "search_files": _SearchFilesArguments,
    "open_file": _OpenFileArguments,
    "send_wechat_message": _WechatArguments,
}
_CONFIRMATION_TOOLS = {"open_application", "open_file", "send_wechat_message"}


class BridgeService:
    def __init__(
        self,
        *,
        device_store: DeviceStore,
        ledger: IdempotencyLedger,
        registry: ToolRegistry,
        pairing_session: PairingSession | None = None,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.device_store = device_store
        self._ledger = ledger
        self._registry = registry
        self._pairing_session = pairing_session
        self._now = now or (lambda: datetime.now(UTC))

    def claim_pairing(self, session_id: str, device_name: str, proof: str) -> PairedDevice:
        session = self._pairing_session
        if session is None or session.session_id != session_id:
            raise BridgeValidationError("unknown pairing session")
        device = session.claim(device_name, proof, self._now())
        self.device_store.save(device)
        return device

    def authenticate(self, request: BridgeRequest, signature: str) -> None:
        device = self.device_store.get_device(request.device_id)
        if device is None:
            raise BridgeAuthenticationError("unknown device")
        if device.revoked:
            raise BridgeAuthenticationError("revoked device")
        secret = self.device_store.get_secret(request.device_id)
        if secret is None:
            raise BridgeAuthenticationError("device credential unavailable")
        try:
            verify_request(secret, request, signature, self._now())
        except AuthenticationError as error:
            raise BridgeAuthenticationError(str(error)) from error

    def submit(self, request: BridgeRequest, signature: str) -> BridgeResponse:
        self.authenticate(request, signature)
        if request.kind != "tool":
            raise BridgeValidationError("only tool requests are accepted by this endpoint")
        tool_name, arguments = self._validate_tool_payload(request.payload)
        risk = (
            Risk.CONFIRMATION_REQUIRED
            if tool_name in _CONFIRMATION_TOOLS
            else Risk.LOW
        )
        state = (
            TaskState.AWAITING_CONFIRMATION
            if risk is Risk.CONFIRMATION_REQUIRED
            else TaskState.PREPARING
        )
        preview = {"tool": tool_name, "arguments": arguments}
        record, created = self._ledger.reserve(
            request,
            tool_name=tool_name,
            arguments=arguments,
            state=state,
            risk=risk,
            response_payload=preview,
        )
        if not created or state is TaskState.AWAITING_CONFIRMATION:
            return record.response()
        return self._execute_once(record).response()

    def get_authenticated_task(
        self,
        request_id: str,
        authentication: BridgeRequest,
        signature: str,
    ) -> BridgeResponse:
        self.authenticate(authentication, signature)
        if authentication.kind != "chat":
            raise BridgeValidationError("task status requires a chat authentication request")
        target = self._validate_target(authentication.payload)
        if target != request_id:
            raise BridgeValidationError("signed target does not match request path")
        return self.get_task(request_id, authentication.device_id)

    def get_task(self, request_id: str, device_id: str) -> BridgeResponse:
        record = self._ledger.get(request_id)
        if record is None:
            raise KeyError(request_id)
        self._require_owner(record, device_id)
        return record.response()

    def confirm(
        self,
        request_id: str,
        confirmation: BridgeRequest,
        signature: str,
    ) -> BridgeResponse:
        self.authenticate(confirmation, signature)
        if confirmation.kind not in {"confirm", "cancel"}:
            raise BridgeValidationError("confirmation endpoint requires confirm or cancel")
        target = self._validate_target(confirmation.payload)
        if target != request_id:
            raise BridgeValidationError("signed target does not match request path")
        record = self._ledger.get(request_id)
        if record is None:
            raise KeyError(request_id)
        self._require_owner(record, confirmation.device_id)
        if confirmation.kind == "cancel":
            return self._ledger.cancel(request_id).response()
        if record.state is not TaskState.AWAITING_CONFIRMATION:
            return record.response()
        return self._execute_once(record).response()

    def _execute_once(self, record: TaskRecord) -> TaskRecord:
        executing, acquired = self._ledger.begin_execution(record.request_id)
        if not acquired:
            return executing
        try:
            result = self._registry.execute(
                ToolProposal(tool_name=executing.tool_name, arguments=executing.arguments)
            )
        except Exception:
            return self._ledger.finish(
                record.request_id,
                state=TaskState.RESULT_UNKNOWN,
                response_payload={"summary": "执行结果未知，请勿自动重试。"},
                result_summary="执行结果未知。",
            )
        state = TaskState.COMPLETED if result.ok else TaskState.FAILED
        return self._ledger.finish(
            record.request_id,
            state=state,
            response_payload={
                "summary": result.message,
                "code": result.code,
                "data": result.data,
            },
            result_summary=result.message,
        )

    def _validate_tool_payload(self, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        try:
            parsed = _ToolPayload.model_validate(payload)
        except ValidationError as error:
            raise BridgeValidationError("invalid tool payload") from error
        argument_model = _REMOTE_ARGUMENT_MODELS.get(parsed.tool)
        if argument_model is None:
            raise BridgeValidationError(f"remote tool is not allowed: {parsed.tool}")
        try:
            self._registry.get(parsed.tool)
        except KeyError as error:
            raise BridgeValidationError(f"remote tool is not configured: {parsed.tool}") from error
        try:
            normalized = argument_model.model_validate(parsed.arguments)
        except ValidationError as error:
            raise BridgeValidationError("invalid tool arguments") from error
        return parsed.tool, normalized.model_dump(mode="json")

    @staticmethod
    def _validate_target(payload: dict[str, Any]) -> str:
        try:
            return _TargetPayload.model_validate(payload).target_request_id
        except ValidationError as error:
            raise BridgeValidationError("invalid target arguments") from error

    @staticmethod
    def _require_owner(record: TaskRecord, device_id: str) -> None:
        if record.device_id != device_id:
            raise BridgeAuthorizationError("only the task owner may access or confirm it")
