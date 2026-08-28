import pytest
from pydantic import ValidationError

from jarvis_assistant.bridge.protocol import BridgeRequest, BridgeResponse, Risk, TaskState


def test_bridge_request_canonical_bytes_match_open_wechat_fixture() -> None:
    """Fails if the signed wire payload changes its field encoding or ordering."""
    request = BridgeRequest(
        version=1,
        request_id="req-1",
        device_id="iphone-1",
        issued_at="2026-08-28T00:00:00Z",
        idempotency_key="idem-1",
        kind="tool",
        payload={"tool": "open_application", "arguments": {"name": "微信"}},
    )

    assert request.canonical_bytes() == (
        b'{"device_id":"iphone-1","idempotency_key":"idem-1",'
        b'"issued_at":"2026-08-28T00:00:00Z","kind":"tool",'
        b'"payload":{"arguments":{"name":"\\u5fae\\u4fe1"},'
        b'"tool":"open_application"},"request_id":"req-1","version":1}'
    )


def test_bridge_request_is_immutable_and_rejects_unknown_fields() -> None:
    """Fails if a signed request can be mutated or extended after validation."""
    request = BridgeRequest(
        version=1,
        request_id="req-1",
        device_id="iphone-1",
        issued_at="2026-08-28T00:00:00Z",
        idempotency_key="idem-1",
        kind="chat",
        payload={},
    )

    with pytest.raises(ValidationError):
        request.request_id = "other"
    with pytest.raises(ValidationError):
        BridgeRequest(
            version=1,
            request_id="req-1",
            device_id="iphone-1",
            issued_at="2026-08-28T00:00:00Z",
            idempotency_key="idem-1",
            kind="chat",
            payload={},
            unexpected=True,
        )


def test_bridge_response_exposes_task_state_and_risk_values() -> None:
    """Fails if consumers cannot construct a response with the public state/risk contract."""
    response = BridgeResponse(
        version=1,
        request_id="req-1",
        state=TaskState.AWAITING_CONFIRMATION,
        risk=Risk.CONFIRMATION_REQUIRED,
        payload={"target": "wechat", "content": "hello"},
    )

    assert response.state == "awaiting_confirmation"
    assert response.risk == "confirmation_required"
