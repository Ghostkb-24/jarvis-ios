from datetime import UTC, datetime

import pytest

from jarvis_assistant.bridge.auth import AuthenticationError, sign_request, verify_request
from jarvis_assistant.bridge.protocol import BridgeRequest

SECRET = b"shared-bridge-secret"
NOW = datetime(2026, 8, 28, 0, 5, tzinfo=UTC)


def make_request(issued_at: str = "2026-08-28T00:00:00Z") -> BridgeRequest:
    return BridgeRequest(
        version=1,
        request_id="req-1",
        device_id="iphone-1",
        issued_at=issued_at,
        idempotency_key="idem-1",
        kind="chat",
        payload={"text": "hello"},
    )


def test_verify_request_accepts_matching_signature_within_time_window() -> None:
    """Fails if a valid signed request cannot authenticate."""
    request = make_request()

    verify_request(SECRET, request, sign_request(SECRET, request), NOW)


def test_verify_request_rejects_signature_after_payload_tampering() -> None:
    """Fails if the verifier accepts a signature for different request bytes."""
    signature = sign_request(SECRET, make_request())
    tampered_request = BridgeRequest(
        version=1,
        request_id="req-1",
        device_id="iphone-1",
        issued_at="2026-08-28T00:00:00Z",
        idempotency_key="idem-1",
        kind="chat",
        payload={"text": "tampered"},
    )

    with pytest.raises(AuthenticationError, match="signature"):
        verify_request(SECRET, tampered_request, signature, NOW)


def test_verify_request_rejects_expired_request() -> None:
    """Fails if requests older than five minutes remain valid."""
    request = make_request("2026-08-27T23:59:59Z")

    with pytest.raises(AuthenticationError, match="expired"):
        verify_request(SECRET, request, sign_request(SECRET, request), NOW)


def test_verify_request_rejects_request_too_far_in_the_future() -> None:
    """Fails if requests more than thirty seconds ahead remain valid."""
    request = make_request("2026-08-28T00:05:31Z")

    with pytest.raises(AuthenticationError, match="future"):
        verify_request(SECRET, request, sign_request(SECRET, request), NOW)


@pytest.mark.parametrize("issued_at", ["not-a-timestamp", "2026-08-28T01:00:00+01:00"])
def test_verify_request_rejects_malformed_or_non_utc_timestamp(issued_at: str) -> None:
    """Fails if timestamp parsing permits malformed or non-UTC request times."""
    request = make_request(issued_at)

    with pytest.raises(AuthenticationError, match="timestamp"):
        verify_request(SECRET, request, sign_request(SECRET, request), NOW)


def test_verify_request_rejects_signature_from_wrong_secret() -> None:
    """Fails if a signature from another paired secret authenticates."""
    request = make_request()
    wrong_signature = sign_request(b"another-device-secret", request)

    with pytest.raises(AuthenticationError, match="signature"):
        verify_request(SECRET, request, wrong_signature, NOW)


@pytest.mark.parametrize("signature", ["not-a-hex-signature", "é"])
def test_verify_request_rejects_malformed_signature(signature: str) -> None:
    """Fails if malformed untrusted signature input escapes as a server error."""
    request = make_request()

    with pytest.raises(AuthenticationError, match="signature"):
        verify_request(SECRET, request, signature, NOW)
