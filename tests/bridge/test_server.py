from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from jarvis_assistant.bridge.auth import sign_request
from jarvis_assistant.bridge.device_store import DeviceStore
from jarvis_assistant.bridge.idempotency import IdempotencyLedger
from jarvis_assistant.bridge.pairing import PairedDevice, PairingSession
from jarvis_assistant.bridge.protocol import BridgeRequest
from jarvis_assistant.bridge.server import (
    BridgeServerController,
    create_bridge_app,
    validate_lan_bind_address,
)
from jarvis_assistant.bridge.service import BridgeService
from jarvis_assistant.storage import SQLiteStore
from jarvis_assistant.tools import default_registry

NOW = datetime(2026, 8, 28, 12, 0, tzinfo=UTC)
SECRET = b"0123456789abcdef0123456789abcdef"


class MemoryCredentialBackend:
    def __init__(self) -> None:
        self.passwords: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.passwords.get((service, username))

    def set_password(self, service: str, username: str, value: str) -> None:
        self.passwords[(service, username)] = value

    def delete_password(self, service: str, username: str) -> None:
        self.passwords.pop((service, username), None)


def make_app(tmp_path: Path) -> tuple[FastAPI, PairingSession, DeviceStore]:
    store = SQLiteStore.open(tmp_path / "state.db")
    backend = MemoryCredentialBackend()
    devices = DeviceStore(store, backend)
    devices.save(
        PairedDevice(
            device_id="iphone-1",
            display_name="Alice's iPhone",
            created_at=NOW,
            last_seen_at=NOW,
            revoked=False,
            secret=SECRET,
        )
    )
    pairing = PairingSession.create(
        bridge_id="bridge-1",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
        now=NOW,
    )
    service = BridgeService(
        device_store=devices,
        ledger=IdempotencyLedger(store),
        registry=default_registry(volume=MemoryVolume()),
        pairing_session=pairing,
        now=lambda: NOW,
    )
    return create_bridge_app(service), pairing, devices


class MemoryVolume:
    def __init__(self) -> None:
        self.value = 10

    def get_volume(self) -> int:
        return self.value

    def set_volume(self, percent: int) -> None:
        self.value = percent


def request_json(
    request: BridgeRequest,
    secret: bytes = SECRET,
) -> dict:
    return {
        "request": request.model_dump(mode="json"),
        "signature": sign_request(secret, request),
    }


def volume_request() -> BridgeRequest:
    return BridgeRequest(
        version=1,
        request_id="req-1",
        device_id="iphone-1",
        issued_at="2026-08-28T12:00:00Z",
        idempotency_key="idem-1",
        kind="tool",
        payload={"tool": "set_volume", "arguments": {"percent": 40}},
    )


async def test_requests_reject_invalid_signature_and_malformed_body(tmp_path: Path) -> None:
    """Fails if the HTTP boundary dispatches invalid or shape-changing input."""
    app, _, _ = make_app(tmp_path)
    request = volume_request()
    invalid = request_json(request)
    invalid["signature"] = "0" * 64

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="https://bridge.test",
    ) as client:
        assert (await client.post("/v1/requests", json=invalid)).status_code == 401
        malformed = request_json(request)
        malformed["unexpected"] = True
        assert (await client.post("/v1/requests", json=malformed)).status_code == 422


async def test_submit_and_signed_status_lookup(tmp_path: Path) -> None:
    """Fails if authenticated task state cannot be retrieved by its owner."""
    app, _, _ = make_app(tmp_path)
    request = volume_request()
    status_request = BridgeRequest(
        version=1,
        request_id="status-1",
        device_id="iphone-1",
        issued_at="2026-08-28T12:00:00Z",
        idempotency_key="status-idem-1",
        kind="chat",
        payload={"target_request_id": "req-1"},
    )

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="https://bridge.test",
    ) as client:
        submitted = await client.post("/v1/requests", json=request_json(request))
        fetched = await client.request(
            "GET",
            "/v1/tasks/req-1",
            json=request_json(status_request),
        )

    assert submitted.status_code == 200
    assert fetched.status_code == 200
    assert fetched.json() == submitted.json()


async def test_pair_claim_succeeds_once_and_persists_device(tmp_path: Path) -> None:
    """Fails if the one-time claim endpoint can be replayed or skips device storage."""
    app, pairing, devices = make_app(tmp_path)
    payload = {
        "session_id": pairing.session_id,
        "device_name": "New iPhone",
        "proof": pairing.proof,
    }

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="https://bridge.test",
    ) as client:
        first = await client.post("/v1/pair/claim", json=payload)
        second = await client.post("/v1/pair/claim", json=payload)

    assert first.status_code == 201
    assert first.json()["device_secret"]
    assert devices.get_device(first.json()["device_id"]) is not None
    assert second.status_code == 409


@pytest.mark.parametrize(
    "address",
    ["0.0.0.0", "127.0.0.1", "169.254.1.5", "8.8.8.8", "bridge.local", "::1"],
)
def test_lan_bind_rejects_wildcard_loopback_public_and_non_ipv4(address: str) -> None:
    """Fails if the Bridge can bind outside an explicitly selected RFC1918 IPv4."""
    with pytest.raises(ValueError, match="private IPv4"):
        validate_lan_bind_address(address)


@pytest.mark.parametrize("address", ["10.0.0.8", "172.16.2.3", "192.168.1.20"])
def test_lan_bind_accepts_explicit_rfc1918_ipv4(address: str) -> None:
    assert validate_lan_bind_address(address) == address


def test_server_controller_start_and_stop_are_socket_testable() -> None:
    """Fails if lifecycle testing requires opening a real network socket."""
    events: list[str] = []

    class FakeServer:
        should_exit = False

        def run(self) -> None:
            events.append("run")

    fake = FakeServer()
    controller = BridgeServerController(
        object(),
        host="192.168.1.20",
        ssl_certfile="bridge-cert.pem",
        ssl_keyfile="bridge-key.pem",
        server_factory=lambda _config: fake,
    )

    controller.start()
    controller.join(timeout=2)
    controller.stop_and_join(timeout=2)

    assert events == ["run"]
    assert fake.should_exit is True


def test_server_controller_requires_tls_material() -> None:
    """Fails if a LAN Bridge can accidentally expose signed requests over HTTP."""
    with pytest.raises(ValueError, match="TLS certificate and private key"):
        BridgeServerController(object(), host="192.168.1.20")
