from __future__ import annotations

import asyncio
import base64
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import status
from fastapi.testclient import TestClient

from jarvis_assistant.bridge.auth import sign_confirmation, sign_request
from jarvis_assistant.bridge.device_store import DeviceStore
from jarvis_assistant.bridge.idempotency import IdempotencyLedger
from jarvis_assistant.bridge.pairing import PairedDevice, PairingSession, PairingSessionOwner
from jarvis_assistant.bridge.protocol import BridgeRequest, TaskConfirmation
from jarvis_assistant.bridge.service import BridgeService
from jarvis_assistant.lan_bridge import LanBridgeAdapter, create_lan_bridge_app
from jarvis_assistant.storage import SQLiteStore
from jarvis_assistant.tools import default_registry

NOW = datetime(2026, 9, 2, 12, 0, tzinfo=UTC)
SECRET = b"0123456789abcdef0123456789abcdef"
PAIRING_FIXTURE = (
    Path(__file__).parents[1]
    / "ios"
    / "Tests"
    / "JarvisProtocolTests"
    / "Fixtures"
    / "pairing-payload.json"
)


class MemoryCredentialBackend:
    def __init__(self) -> None:
        self.passwords: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.passwords.get((service, username))

    def set_password(self, service: str, username: str, value: str) -> None:
        self.passwords[(service, username)] = value

    def delete_password(self, service: str, username: str) -> None:
        self.passwords.pop((service, username), None)


class MemoryVolume:
    def __init__(self) -> None:
        self.value = 10
        self.set_values: list[int] = []

    def get_volume(self) -> int:
        return self.value

    def set_volume(self, percent: int) -> None:
        self.value = percent
        self.set_values.append(percent)


def make_adapter(
    tmp_path: Path,
) -> tuple[LanBridgeAdapter, MemoryVolume, list[tuple[str, str]], DeviceStore]:
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
    volume = MemoryVolume()
    sent_messages: list[tuple[str, str]] = []
    registry = default_registry(
        volume=volume,
        wechat_sender=lambda contact, message: not sent_messages.append((contact, message)),
    )
    pairing_owner = PairingSessionOwner(
        bridge_id="bridge-1",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
        now=lambda: NOW,
    )
    service = BridgeService(
        device_store=devices,
        ledger=IdempotencyLedger(store),
        registry=registry,
        pairing_session_owner=pairing_owner,
        now=lambda: NOW,
    )
    return (
        LanBridgeAdapter(service=service, pairing_session_owner=pairing_owner),
        volume,
        sent_messages,
        devices,
    )


def request_json(request: BridgeRequest, secret: bytes = SECRET) -> dict:
    return {
        "request": request.model_dump(mode="json"),
        "signature": sign_request(secret, request),
    }


def confirmation_json(
    request: BridgeRequest,
    confirmation: TaskConfirmation,
    secret: bytes = SECRET,
) -> dict:
    return {
        "request": request.model_dump(mode="json"),
        "confirmation": confirmation.model_dump(mode="json"),
        "signature": sign_confirmation(secret, request, confirmation),
    }


def tool_request(
    *,
    request_id: str = "req-1",
    tool: str = "set_volume",
    arguments: dict | None = None,
) -> BridgeRequest:
    return BridgeRequest(
        version=1,
        request_id=request_id,
        device_id="iphone-1",
        issued_at="2026-09-02T12:00:00Z",
        idempotency_key=f"idem-{request_id}",
        kind="tool",
        payload={"tool": tool, "arguments": arguments or {"percent": 35}},
    )


def auth_request(request_id: str) -> BridgeRequest:
    return BridgeRequest(
        version=1,
        request_id=f"status-{request_id}",
        device_id="iphone-1",
        issued_at="2026-09-02T12:00:00Z",
        idempotency_key=f"status-{request_id}",
        kind="chat",
        payload={"target_request_id": request_id},
    )


def confirm_request(request_id: str, *, kind: str = "confirm") -> BridgeRequest:
    return BridgeRequest(
        version=1,
        request_id=f"{kind}-{request_id}",
        device_id="iphone-1",
        issued_at="2026-09-02T12:00:00Z",
        idempotency_key=f"{kind}-idem-{request_id}",
        kind=kind,
        payload={"target_request_id": request_id},
    )


def approval(request_id: str, confirmation_request: BridgeRequest) -> TaskConfirmation:
    return TaskConfirmation(
        version=1,
        request_id=confirmation_request.request_id,
        task_id=request_id,
        decision="approve" if confirmation_request.kind == "confirm" else "decline",
        decided_at="2026-09-02T12:00:00Z",
    )


def test_desktop_qr_payload_matches_ios_protocol_fixture() -> None:
    expected = json.loads(PAIRING_FIXTURE.read_text(encoding="utf-8"))
    session = PairingSession(
        bridge_id=expected["bridge_id"],
        bridge_url=expected["bridge_url"],
        certificate_sha256=expected["certificate_sha256"],
        session_id=expected["session_id"],
        expires_at=datetime.fromisoformat(expected["expires_at"].replace("Z", "+00:00")),
        proof=expected["proof"],
    )

    assert session.qr_payload == {
        **expected,
        "expires_at": "2099-09-02T12:02:00+00:00",
    }


def test_pairing_claim_returns_persisted_identity_and_subsequent_auth_uses_it(
    tmp_path: Path,
) -> None:
    adapter, volume, _, devices = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    pairing = adapter._pairing_session_owner.session_for_display()  # noqa: SLF001

    with TestClient(app) as client:
        response = client.post(
            "/v1/pair/claim",
            json={
                "session_id": pairing.session_id,
                "device_name": "Alice's iPhone",
                "proof": pairing.proof,
                "device_public_key": "cd" * 32,
            },
        )

    assert response.status_code == status.HTTP_201_CREATED
    persisted_device_id = response.json()["device_id"]
    assert persisted_device_id
    assert devices.get_device(persisted_device_id) is not None
    assert response.json()["device_public_key"] == "cd" * 32
    assert adapter.device_public_key_for(persisted_device_id) == "cd" * 32

    paired_secret = base64.b64decode(
        response.json()["device_secret"],
        altchars=b"-_",
        validate=True,
    )
    request = BridgeRequest(
        version=1,
        request_id="paired-req-1",
        device_id=persisted_device_id,
        issued_at="2026-09-02T12:00:00Z",
        idempotency_key="paired-idem-1",
        kind="tool",
        payload={"tool": "set_volume", "arguments": {"percent": 55}},
    )

    with TestClient(app) as client:
        submit = client.post("/v1/requests", json=request_json(request, paired_secret))

    assert submit.status_code == status.HTTP_200_OK
    assert volume.set_values == [55]


def test_pairing_claim_rejects_legacy_challenge_route_and_extra_fields(tmp_path: Path) -> None:
    adapter, _, _, _ = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    pairing = adapter._pairing_session_owner.session_for_display()  # noqa: SLF001
    claim = {
        "session_id": pairing.session_id,
        "device_name": "Alice's iPhone",
        "proof": pairing.proof,
        "device_public_key": "cd" * 32,
    }

    with TestClient(app) as client:
        legacy = client.post("/v1/pair/challenge", json=claim)
        claim["device_id"] = "client-selected-id"
        extra_field = client.post("/v1/pair/claim", json=claim)

    assert legacy.status_code == status.HTTP_404_NOT_FOUND
    assert extra_field.status_code == status.HTTP_422_UNPROCESSABLE_CONTENT


def test_requests_reject_invalid_signature(tmp_path: Path) -> None:
    adapter, _, _, _ = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    request = tool_request()
    invalid = request_json(request)
    invalid["signature"] = "0" * 64

    with TestClient(app) as client:
        response = client.post("/v1/requests", json=invalid)

    assert response.status_code == status.HTTP_401_UNAUTHORIZED


def test_duplicate_low_risk_submission_returns_same_terminal_event(tmp_path: Path) -> None:
    adapter, volume, _, _ = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    request = tool_request()

    with TestClient(app) as client:
        first = client.post("/v1/requests", json=request_json(request))
        second = client.post("/v1/requests", json=request_json(request))

    assert first.status_code == status.HTTP_200_OK
    assert first.json() == second.json()
    assert first.json()["state"] == "completed"
    assert volume.set_values == [35]


@pytest.mark.asyncio
async def test_event_broker_replays_terminal_event_published_before_subscribe(
    tmp_path: Path,
) -> None:
    adapter, _, _, _ = make_adapter(tmp_path)
    terminal = {
        "version": 1,
        "request_id": "race-1",
        "task_id": "race-1",
        "state": "completed",
        "summary": "done",
        "output": {},
    }

    await adapter._broker.publish("race-1", terminal)  # noqa: SLF001
    queue = await adapter._broker.subscribe("race-1")  # noqa: SLF001

    assert await asyncio.wait_for(queue.get(), timeout=0.1) == terminal


def test_confirmation_and_websocket_stream_deliver_preview_then_terminal(tmp_path: Path) -> None:
    adapter, _, sent_messages, _ = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    request = tool_request(
        tool="send_wechat_message",
        arguments={"contact": "Alice", "message": "Meet at eight"},
    )
    confirmation_request = confirm_request(request.request_id)
    approved = approval(request.request_id, confirmation_request)

    with TestClient(app) as client:
        submitted = client.post("/v1/requests", json=request_json(request))
        assert submitted.status_code == status.HTTP_202_ACCEPTED
        with client.websocket_connect(f"/v1/tasks/{request.request_id}/events") as websocket:
            websocket.send_json(request_json(auth_request(request.request_id)))
            preview = websocket.receive_json()
            confirmed = client.post(
                f"/v1/tasks/{request.request_id}/confirm",
                json=confirmation_json(confirmation_request, approved),
            )
            terminal = websocket.receive_json()

    assert preview["summary"] == "发送前请你确认"
    assert preview["target"] == "微信"
    assert confirmed.status_code == status.HTTP_200_OK
    assert terminal["state"] == "completed"
    assert terminal["summary"] == "微信消息已发送。"
    assert sent_messages == [("Alice", "Meet at eight")]


def test_blocked_risk_refusal_returns_protocol_rejection(tmp_path: Path) -> None:
    adapter, _, _, _ = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    request = tool_request(
        tool="send_wechat_message",
        arguments={"contact": "Alice", "message": "替我输入这个支付密码"},
    )

    with TestClient(app) as client:
        response = client.post("/v1/requests", json=request_json(request))

    assert response.status_code == status.HTTP_403_FORBIDDEN
    assert response.json()["reason"] == "password_entry_blocked"
    assert response.json()["retryable"] is False


def test_blocked_confirmation_never_leaks_another_devices_task(tmp_path: Path) -> None:
    adapter, _, _, devices = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    devices.save(
        PairedDevice(
            device_id="iphone-2",
            display_name="Bob's iPhone",
            created_at=NOW,
            last_seen_at=NOW,
            revoked=False,
            secret=b"abcdef0123456789abcdef0123456789",
        )
    )
    blocked_request = tool_request(
        tool="send_wechat_message",
        arguments={"contact": "Alice", "message": "替我输入这个支付密码"},
    )
    other_confirmation = BridgeRequest(
        version=1,
        request_id="confirm-foreign",
        device_id="iphone-2",
        issued_at="2026-09-02T12:00:00Z",
        idempotency_key="confirm-foreign-idem",
        kind="confirm",
        payload={"target_request_id": blocked_request.request_id},
    )
    allowed = TaskConfirmation(
        version=1,
        request_id=other_confirmation.request_id,
        task_id=blocked_request.request_id,
        decision="approve",
        decided_at="2026-09-02T12:00:00Z",
    )

    with TestClient(app) as client:
        blocked = client.post("/v1/requests", json=request_json(blocked_request))
        denied = client.post(
            f"/v1/tasks/{blocked_request.request_id}/confirm",
            json=confirmation_json(
                other_confirmation,
                allowed,
                b"abcdef0123456789abcdef0123456789",
            ),
        )

    assert blocked.status_code == status.HTTP_403_FORBIDDEN
    assert denied.status_code == status.HTTP_403_FORBIDDEN
    assert denied.json()["detail"] == "only the task owner may access or confirm it"


def test_websocket_disconnect_cleanup_removes_subscriber(tmp_path: Path) -> None:
    adapter, _, _, _ = make_adapter(tmp_path)
    app = create_lan_bridge_app(adapter)
    request = tool_request(
        tool="send_wechat_message",
        arguments={"contact": "Alice", "message": "Meet at eight"},
    )

    with TestClient(app) as client:
        client.post("/v1/requests", json=request_json(request))
        with client.websocket_connect(f"/v1/tasks/{request.request_id}/events") as websocket:
            websocket.send_json(request_json(auth_request(request.request_id)))
            _ = websocket.receive_json()
            assert adapter.subscriber_count(request.request_id) == 1
        assert adapter.subscriber_count(request.request_id) == 0
