from __future__ import annotations

import base64
import ipaddress
from collections.abc import Callable
from threading import Lock, Thread
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from jarvis_assistant.bridge.idempotency import IdempotencyConflict
from jarvis_assistant.bridge.pairing import PairingClaimError
from jarvis_assistant.bridge.protocol import BridgeRequest, BridgeResponse, TaskState
from jarvis_assistant.bridge.service import (
    BridgeAuthenticationError,
    BridgeAuthorizationError,
    BridgeService,
    BridgeValidationError,
)

_RFC1918_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SignedBridgeRequest(_StrictModel):
    request: BridgeRequest
    signature: str = Field(min_length=1)


class PairClaimRequest(_StrictModel):
    session_id: str = Field(min_length=1)
    device_name: str = Field(min_length=1)
    proof: str = Field(min_length=1)


def create_bridge_app(service: BridgeService) -> FastAPI:
    app = FastAPI(title="Jarvis Bridge", version="1")

    @app.post("/v1/pair/claim", status_code=status.HTTP_201_CREATED)
    async def claim_pairing(claim: PairClaimRequest) -> dict[str, Any]:
        try:
            device = service.claim_pairing(claim.session_id, claim.device_name, claim.proof)
        except PairingClaimError as error:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
        except BridgeValidationError as error:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
        return {
            "version": 1,
            "device_id": device.device_id,
            "device_secret": base64.urlsafe_b64encode(device.secret).decode("ascii"),
        }

    @app.post("/v1/requests", response_model=BridgeResponse)
    async def submit_request(envelope: SignedBridgeRequest) -> JSONResponse:
        try:
            response = service.submit(envelope.request, envelope.signature)
        except Exception as error:
            _raise_http_error(error)
        response_status = (
            status.HTTP_202_ACCEPTED
            if response.state is TaskState.AWAITING_CONFIRMATION
            else status.HTTP_200_OK
        )
        return JSONResponse(
            status_code=response_status,
            content=response.model_dump(mode="json"),
        )

    @app.get("/v1/tasks/{request_id}", response_model=BridgeResponse)
    async def get_task(
        request_id: str,
        envelope: SignedBridgeRequest,
    ) -> BridgeResponse:
        try:
            return service.get_authenticated_task(
                request_id,
                envelope.request,
                envelope.signature,
            )
        except Exception as error:
            _raise_http_error(error)

    @app.post("/v1/tasks/{request_id}/confirm", response_model=BridgeResponse)
    async def confirm_task(
        request_id: str,
        envelope: SignedBridgeRequest,
    ) -> BridgeResponse:
        try:
            return service.confirm(request_id, envelope.request, envelope.signature)
        except Exception as error:
            _raise_http_error(error)

    return app


def _raise_http_error(error: Exception) -> None:
    if isinstance(error, BridgeAuthenticationError):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(error)) from error
    if isinstance(error, BridgeAuthorizationError):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    if isinstance(error, KeyError):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="task not found",
        ) from error
    if isinstance(error, IdempotencyConflict):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    if isinstance(error, BridgeValidationError):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=str(error),
        ) from error
    raise error


def validate_lan_bind_address(address: str) -> str:
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError as error:
        raise ValueError("Bridge bind address must be an explicit private IPv4 address") from error
    if parsed.version != 4 or not any(parsed in network for network in _RFC1918_NETWORKS):
        raise ValueError("Bridge bind address must be an explicit private IPv4 address")
    return str(parsed)


class BridgeServerController:
    def __init__(
        self,
        app: Any,
        *,
        host: str,
        port: int = 8443,
        ssl_certfile: str | None = None,
        ssl_keyfile: str | None = None,
        server_factory: Callable[[uvicorn.Config], Any] = uvicorn.Server,
    ) -> None:
        validated_host = validate_lan_bind_address(host)
        if not ssl_certfile or not ssl_keyfile:
            raise ValueError("Bridge requires a TLS certificate and private key")
        config = uvicorn.Config(
            app=app,
            host=validated_host,
            port=port,
            ssl_certfile=ssl_certfile,
            ssl_keyfile=ssl_keyfile,
            log_level="warning",
        )
        self._server = server_factory(config)
        self._thread: Thread | None = None
        self._lock = Lock()

    def start(self) -> None:
        with self._lock:
            if self._thread is not None:
                return
            self._thread = Thread(
                target=self._server.run,
                name="jarvis-mobile-bridge",
                daemon=True,
            )
            self._thread.start()

    def request_stop(self) -> None:
        self._server.should_exit = True

    def join(self, timeout: float | None = 5.0) -> None:
        thread = self._thread
        if thread is None:
            return
        thread.join(timeout)
        if thread.is_alive():
            raise TimeoutError("Jarvis mobile Bridge server did not stop")

    def stop_and_join(self, timeout: float | None = 5.0) -> None:
        self.request_stop()
        self.join(timeout)
