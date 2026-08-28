from __future__ import annotations

import hmac
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from threading import Barrier

import pytest

from jarvis_assistant.bridge.pairing import (
    PairingClaimError,
    PairingSession,
    PairingSessionOwner,
)

NOW = datetime(2026, 8, 28, 12, 0, tzinfo=UTC)


def make_session() -> PairingSession:
    return PairingSession.create(
        bridge_id="bridge-01",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
        now=NOW,
    )


@pytest.mark.parametrize(
    "bridge_url",
    [
        "http://192.168.1.20:8443",
        "https://8.8.8.8:8443",
        "https://134744072:8443",
        "https://0x08080808:8443",
        "https://example.com:8443",
        "https://user:password@192.168.1.20:8443",
    ],
)
def test_create_rejects_non_https_or_non_private_bridge_url(bridge_url: str) -> None:
    with pytest.raises(ValueError, match="private HTTPS"):
        PairingSession.create(
            bridge_id="bridge-01",
            bridge_url=bridge_url,
            certificate_sha256="ab" * 32,
            now=NOW,
        )


@pytest.mark.parametrize("fingerprint", ["AB" * 32, "ab" * 31, "zz" * 32])
def test_create_rejects_malformed_certificate_fingerprint(fingerprint: str) -> None:
    with pytest.raises(ValueError, match="fingerprint"):
        PairingSession.create(
            bridge_id="bridge-01",
            bridge_url="https://192.168.1.20:8443",
            certificate_sha256=fingerprint,
            now=NOW,
        )


def test_create_canonicalizes_trailing_dot_bridge_url() -> None:
    session = PairingSession.create(
        bridge_id="bridge-01",
        bridge_url="https://bridge.local.:8443",
        certificate_sha256="ab" * 32,
        now=NOW,
    )

    assert session.bridge_url == "https://bridge.local:8443"
    assert session.qr_payload["bridge_url"] == "https://bridge.local:8443"


def test_claim_succeeds_only_once() -> None:
    session = make_session()

    device = session.claim("Alice's iPhone", session.proof, NOW + timedelta(seconds=1))

    assert device.display_name == "Alice's iPhone"
    assert device.created_at == NOW + timedelta(seconds=1)
    assert device.last_seen_at == device.created_at
    assert device.revoked is False
    assert len(device.device_id) >= 32
    assert len(device.secret) >= 32
    with pytest.raises(PairingClaimError, match="already claimed"):
        session.claim("Other iPhone", session.proof, NOW + timedelta(seconds=2))


def test_simultaneous_claims_allow_exactly_one_success(monkeypatch: pytest.MonkeyPatch) -> None:
    session = make_session()
    comparison_barrier = Barrier(2)
    real_compare_digest = hmac.compare_digest

    def synchronized_compare_digest(left: bytes, right: bytes) -> bool:
        comparison_barrier.wait(timeout=2)
        return real_compare_digest(left, right)

    monkeypatch.setattr(hmac, "compare_digest", synchronized_compare_digest)

    def claim() -> str:
        try:
            session.claim("Alice's iPhone", session.proof, NOW + timedelta(seconds=1))
        except PairingClaimError as error:
            return str(error)
        return "success"

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(claim) for _ in range(2)]
        outcomes = [future.result(timeout=3) for future in futures]

    assert outcomes.count("success") == 1
    assert outcomes.count("pairing session already claimed") == 1


def test_claim_rejects_expired_session() -> None:
    session = make_session()

    with pytest.raises(PairingClaimError, match="expired"):
        session.claim("Alice's iPhone", session.proof, NOW + timedelta(seconds=120))


@pytest.mark.parametrize("bad_proof", ["wrong-proof", "é"])
def test_claim_rejects_bad_proof_without_consuming_session(bad_proof: str) -> None:
    session = make_session()

    with pytest.raises(PairingClaimError, match="invalid proof"):
        session.claim("Alice's iPhone", bad_proof, NOW + timedelta(seconds=1))

    device = session.claim("Alice's iPhone", session.proof, NOW + timedelta(seconds=2))
    assert device.display_name == "Alice's iPhone"


@pytest.mark.parametrize("device_name", ["", " ", "\t\n"])
def test_claim_rejects_blank_device_name(device_name: str) -> None:
    session = make_session()

    with pytest.raises(PairingClaimError, match="device name"):
        session.claim(device_name, session.proof, NOW + timedelta(seconds=1))


def test_qr_payload_contains_connection_data_but_no_long_term_secret() -> None:
    session = make_session()

    payload = session.qr_payload

    assert payload == {
        "version": 1,
        "bridge_id": "bridge-01",
        "bridge_url": "https://192.168.1.20:8443",
        "certificate_sha256": "ab" * 32,
        "session_id": session.session_id,
        "expires_at": "2026-08-28T12:02:00+00:00",
        "proof": session.proof,
    }
    assert "secret" not in repr(session)
    assert "device_secret" not in payload


def make_owner(clock: list[datetime]) -> PairingSessionOwner:
    return PairingSessionOwner(
        bridge_id="bridge-01",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
        now=lambda: clock[0],
    )


def test_pairing_owner_creates_one_live_session_for_initial_display() -> None:
    """Fails if the first QR is absent or each click invalidates a live session."""
    owner = make_owner([NOW])

    first = owner.session_for_display()
    second = owner.session_for_display()

    assert second is first


def test_pairing_owner_rotates_an_expired_session() -> None:
    """Fails if an expired QR remains visible and unclaimable."""
    clock = [NOW]
    owner = make_owner(clock)
    expired = owner.session_for_display()

    clock[0] = NOW + timedelta(seconds=120)
    rotated = owner.session_for_display()

    assert rotated.session_id != expired.session_id
    assert rotated.proof != expired.proof


def test_pairing_owner_rotates_a_claimed_session() -> None:
    """Fails if the next QR reuses proof after a successful claim."""
    clock = [NOW]
    owner = make_owner(clock)
    claimed = owner.session_for_display()
    owner.claim(claimed.session_id, "Alice's iPhone", claimed.proof)

    rotated = owner.session_for_display()

    assert rotated.session_id != claimed.session_id
    assert rotated.proof != claimed.proof
