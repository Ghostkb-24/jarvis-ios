from __future__ import annotations

import asyncio
import base64
from collections import defaultdict
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from jarvis_assistant.bridge.device_store import DeviceStore
from jarvis_assistant.bridge.idempotency import IdempotencyConflict, IdempotencyLedger
from jarvis_assistant.bridge.pairing import PairingClaimError, PairingSessionOwner
from jarvis_assistant.bridge.protocol import (
    BridgeRequest,
    BridgeResponse,
    Risk,
    TaskConfirmation,
    TaskState,
)
from jarvis_assistant.bridge.server import BridgeServerController, validate_lan_bind_address
from jarvis_assistant.bridge.service import (
    BridgeAuthenticationError,
    BridgeAuthorizationError,
    BridgeService,
    BridgeValidationError,
)
from jarvis_assistant.bridge.tls import BridgeTLSIdentity, create_server_ssl_context
from jarvis_assistant.storage import CredentialStore, SQLiteStore
from jarvis_assistant.tools import ToolRegistry


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SignedBridgeRequest(_StrictModel):
    request: BridgeRequest
    signature: str = Field(min_length=1)


class SignedTaskConfirmation(_StrictModel):
    request: BridgeRequest
    confirmation: TaskConfirmation
    signature: str = Field(min_length=1)


class PairingClaimRequest(_StrictModel):
    session_id: str = Field(min_length=1)
    device_name: str = Field(min_length=1)
    proof: str = Field(min_length=1)
    device_public_key: str = Field(min_length=64, max_length=64)


@dataclass(frozen=True)
class LanBridgeComposition:
    controller: BridgeServerController
    pairing_session_owner: PairingSessionOwner


class _EventBroker:
    def __init__(self) -> None:
        self._queues: dict[str, set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)
        self._latest: dict[str, dict[str, Any]] = {}
        self._lock = asyncio.Lock()

    async def publish(self, request_id: str, payload: dict[str, Any]) -> None:
        async with self._lock:
            if request_id not in self._latest and len(self._latest) >= 1024:
                self._latest.pop(next(iter(self._latest)))
            self._latest[request_id] = payload
            queues = list(self._queues.get(request_id, ()))
        for queue in queues:
            await queue.put(payload)

    async def subscribe(self, request_id: str) -> asyncio.Queue[dict[str, Any]]:
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        async with self._lock:
            self._queues[request_id].add(queue)
            latest = self._latest.get(request_id)
            if latest is not None:
                queue.put_nowait(latest)
        return queue

    async def unsubscribe(self, request_id: str, queue: asyncio.Queue[dict[str, Any]]) -> None:
        async with self._lock:
            subscribers = self._queues.get(request_id)
            if subscribers is None:
                return
            subscribers.discard(queue)
            if not subscribers:
                self._queues.pop(request_id, None)

    def subscriber_count(self, request_id: str) -> int:
        return len(self._queues.get(request_id, ()))


class LanBridgeAdapter:
    def __init__(
        self,
        *,
        service: BridgeService,
        pairing_session_owner: PairingSessionOwner,
        now: callable | None = None,
    ) -> None:
        self.service = service
        self._pairing_session_owner = pairing_session_owner
        self._now = now or (lambda: datetime.now(UTC))
        self._broker = _EventBroker()
        self._device_public_keys: dict[str, str] = {}

    def subscriber_count(self, request_id: str) -> int:
        return self._broker.subscriber_count(request_id)

    def device_public_key_for(self, device_id: str) -> str | None:
        return self._device_public_keys.get(device_id)

    def claim_pairing(self, payload: PairingClaimRequest) -> dict[str, Any]:
        try:
            device = self.service.claim_pairing(
                payload.session_id,
                payload.device_name,
                payload.proof,
            )
        except PairingClaimError as error:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
        self._device_public_keys[device.device_id] = payload.device_public_key
        return {
            "version": 1,
            "device_id": device.device_id,
            "device_public_key": self._device_public_keys[device.device_id],
            "device_secret": base64.urlsafe_b64encode(device.secret).decode("ascii"),
        }

    async def submit(self, envelope: SignedBridgeRequest) -> JSONResponse:
        request = envelope.request
        rejection = self._blocked_rejection(request)
        if rejection is not None:
            self.service.authenticate(request, envelope.signature)
            self._reserve_blocked_request(request, rejection)
            await self._broker.publish(request.request_id, rejection)
            return JSONResponse(status_code=status.HTTP_403_FORBIDDEN, content=rejection)
        try:
            response = await self.service.submit_async(request, envelope.signature)
        except Exception as error:
            self._raise_http_error(error)
        payload = self._event_payload(response, request=request)
        await self._broker.publish(request.request_id, payload)
        response_status = (
            status.HTTP_202_ACCEPTED
            if response.state is TaskState.AWAITING_CONFIRMATION
            else status.HTTP_200_OK
        )
        return JSONResponse(status_code=response_status, content=payload)

    def get_task(self, request_id: str, envelope: SignedBridgeRequest) -> dict[str, Any]:
        try:
            response = self.service.get_authenticated_task(
                request_id,
                envelope.request,
                envelope.signature,
            )
        except Exception as error:
            self._raise_http_error(error)
        return self._event_payload(response)

    async def confirm(self, request_id: str, envelope: SignedTaskConfirmation) -> JSONResponse:
        request = envelope.request
        rejection = self._blocked_rejection_for_confirmation(request_id)
        if rejection is not None:
            try:
                self.service.authenticate(request, envelope.signature, envelope.confirmation)
                self._authorize_task_owner(request_id, request.device_id)
            except Exception as error:
                self._raise_http_error(error)
            await self._broker.publish(request_id, rejection)
            return JSONResponse(status_code=status.HTTP_403_FORBIDDEN, content=rejection)
        try:
            response = self.service.confirm(
                request_id,
                request,
                envelope.confirmation,
                envelope.signature,
            )
        except Exception as error:
            self._raise_http_error(error)
        payload = self._event_payload(response)
        await self._broker.publish(request_id, payload)
        return JSONResponse(status_code=status.HTTP_200_OK, content=payload)

    async def event_stream(
        self,
        request_id: str,
        envelope: SignedBridgeRequest,
    ) -> AsyncIterator[dict[str, Any]]:
        current = self.get_task(request_id, envelope)
        queue = await self._broker.subscribe(request_id)
        try:
            yield current
            while (
                current.get("state")
                not in {"completed", "failed", "cancelled", "result_unknown"}
                and "reason" not in current
            ):
                next_event = await queue.get()
                if next_event == current:
                    continue
                current = next_event
                yield current
        finally:
            await self._broker.unsubscribe(request_id, queue)

    def _reserve_blocked_request(self, request: BridgeRequest, rejection: dict[str, Any]) -> None:
        response_payload = {"summary": rejection["message"], "reason": rejection["reason"]}
        self.service._ledger.reserve(  # noqa: SLF001
            request,
            tool_name=self._tool_name(request),
            arguments=request.payload.get("arguments", {}),
            state=TaskState.FAILED,
            risk=Risk.CONFIRMATION_REQUIRED,
            response_payload=response_payload,
        )

    def _event_payload(
        self,
        response: BridgeResponse,
        *,
        request: BridgeRequest | None = None,
    ) -> dict[str, Any]:
        request_id = response.request_id
        task_id = request_id
        payload = response.payload
        if response.state is TaskState.AWAITING_CONFIRMATION:
            tool = self._tool_name(request) if request is not None else str(payload.get("tool", ""))
            arguments = payload.get("arguments", {})
            title, summary, action, target = self._preview_metadata(tool, arguments)
            return {
                "version": 1,
                "request_id": request_id,
                "task_id": task_id,
                "risk": response.risk.value,
                "title": title,
                "summary": summary,
                "action": action,
                "target": target,
                "arguments": arguments,
            }
        if response.state in {TaskState.PREPARING, TaskState.EXECUTING}:
            return {
                "version": 1,
                "request_id": request_id,
                "task_id": task_id,
                "state": response.state.value,
                "progress_message": str(payload.get("summary", "正在执行。")),
                "event_index": 0,
            }
        return {
            "version": 1,
            "request_id": request_id,
            "task_id": task_id,
            "state": response.state.value,
            "summary": str(payload.get("summary", "")),
            "output": payload,
        }

    def _blocked_rejection(self, request: BridgeRequest) -> dict[str, Any] | None:
        reason = self._blocked_reason(request)
        if reason is None:
            return None
        return {
            "version": 1,
            "request_id": request.request_id,
            "task_id": request.request_id,
            "reason": reason,
            "message": _blocked_message(reason),
            "retryable": False,
        }

    def _blocked_rejection_for_confirmation(self, request_id: str) -> dict[str, Any] | None:
        record = self.service._ledger.get(request_id)  # noqa: SLF001
        if record is None:
            return None
        payload = {
            "tool": record.tool_name,
            "arguments": record.arguments,
        }
        request = BridgeRequest(
            version=1,
            request_id=request_id,
            device_id=record.device_id,
            issued_at=self._timestamp(self._now()),
            idempotency_key=record.idempotency_key,
            kind="tool",
            payload=payload,
        )
        return self._blocked_rejection(request)

    def _authorize_task_owner(self, request_id: str, device_id: str) -> None:
        record = self.service._ledger.get(request_id)  # noqa: SLF001
        if record is None:
            raise KeyError(request_id)
        self.service._require_owner(record, device_id)  # noqa: SLF001

    def _blocked_reason(self, request: BridgeRequest) -> str | None:
        body = str(request.payload).casefold()
        if any(token in body for token in ("password", "密码", "支付密码", "passcode", "pin")):
            return "password_entry_blocked"
        if any(token in body for token in ("支付", "付款", "转账", "汇款", "pay")):
            return "payment_blocked"
        if any(token in body for token in ("删除文件", "删掉", "删文件", "delete file", "删除")):
            return "file_deletion_blocked"
        return None

    @staticmethod
    def _preview_metadata(tool_name: str, arguments: Any) -> tuple[str, str, str, str]:
        if tool_name == "send_wechat_message":
            return ("发送微信消息", "发送前请你确认", "发送消息", "微信")
        if tool_name == "open_application":
            return (
                "打开应用",
                "执行前请你确认",
                "打开应用",
                str(arguments.get("name", "应用")),
            )
        if tool_name == "open_file":
            return (
                "打开文件",
                "执行前请你确认",
                "打开文件",
                Path(str(arguments.get("path", ""))).name,
            )
        return (tool_name, "执行前请你确认", tool_name, tool_name)

    @staticmethod
    def _tool_name(request: BridgeRequest) -> str:
        value = request.payload.get("tool")
        return str(value) if isinstance(value, str) else ""

    @staticmethod
    def _timestamp(value: datetime) -> str:
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")

    @staticmethod
    def _raise_http_error(error: Exception) -> None:
        if isinstance(error, BridgeAuthenticationError):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=str(error),
            ) from error
        if isinstance(error, BridgeAuthorizationError):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=str(error),
            ) from error
        if isinstance(error, KeyError):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="task not found",
            ) from error
        if isinstance(error, IdempotencyConflict):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=str(error),
            ) from error
        if isinstance(error, BridgeValidationError):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=str(error),
            ) from error
        raise error


def create_lan_bridge_app(adapter: LanBridgeAdapter) -> FastAPI:
    app = FastAPI(title="Jarvis LAN Bridge", version="1")
    app.state.adapter = adapter

    @app.post("/v1/pair/claim", status_code=status.HTTP_201_CREATED)
    async def claim_pairing(request: PairingClaimRequest) -> dict[str, Any]:
        return adapter.claim_pairing(request)

    @app.post("/v1/requests")
    async def submit_request(envelope: SignedBridgeRequest) -> JSONResponse:
        return await adapter.submit(envelope)

    @app.get("/v1/tasks/{request_id}")
    async def get_task(request_id: str, envelope: SignedBridgeRequest) -> dict[str, Any]:
        return adapter.get_task(request_id, envelope)

    @app.post("/v1/tasks/{request_id}/confirm")
    async def confirm_task(
        request_id: str,
        envelope: SignedTaskConfirmation,
    ) -> JSONResponse:
        return await adapter.confirm(request_id, envelope)

    @app.websocket("/v1/tasks/{request_id}/events")
    async def task_events(request_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        try:
            payload = SignedBridgeRequest.model_validate(await websocket.receive_json())
            async for event in adapter.event_stream(request_id, payload):
                await websocket.send_json(event)
        except WebSocketDisconnect:
            return
        finally:
            await websocket.close()

    return app


def compose_lan_bridge(
    *,
    store: SQLiteStore,
    registry: ToolRegistry,
    base_dir: Path,
    credentials: CredentialStore,
    host: str,
    chat_dispatcher: Callable[[str], Awaitable[str]] | None = None,
    now: callable | None = None,
    controller_factory: type[BridgeServerController] | None = None,
) -> LanBridgeComposition:
    validated_host = validate_lan_bind_address(host)
    identity = BridgeTLSIdentity.load_or_create(
        certificate_path=base_dir / "bridge-cert.pem",
        credential_backend=credentials._backend,
        bridge_id="jarvis-desktop",
        hosts=(validated_host,),
    )
    ssl_context = create_server_ssl_context(
        identity,
        certificate_path=base_dir / "bridge-cert.pem",
        temporary_directory=base_dir,
    )
    pairing_owner = PairingSessionOwner(
        bridge_id="jarvis-desktop",
        bridge_url=f"https://{validated_host}:8443",
        certificate_sha256=identity.certificate_sha256,
        now=now,
    )
    service = BridgeService(
        device_store=DeviceStore(store, credentials._backend),
        ledger=IdempotencyLedger(store),
        registry=registry,
        pairing_session_owner=pairing_owner,
        chat_dispatcher=chat_dispatcher,
        now=now,
    )
    adapter = LanBridgeAdapter(
        service=service,
        pairing_session_owner=pairing_owner,
        now=now,
    )
    controller_type = controller_factory or BridgeServerController
    controller = controller_type(
        create_lan_bridge_app(adapter),
        host=validated_host,
        ssl_context=ssl_context,
    )
    return LanBridgeComposition(controller=controller, pairing_session_owner=pairing_owner)


def _blocked_message(reason: str) -> str:
    messages = {
        "payment_blocked": "涉及付款，已拒绝执行。",
        "file_deletion_blocked": "涉及删除文件，已拒绝执行。",
        "password_entry_blocked": "涉及密码输入，已拒绝执行。",
    }
    return messages[reason]
