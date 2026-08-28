from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from jarvis_assistant.bridge.pairing import PairingClaimError, PairingSession

NOW = datetime(2026, 8, 28, 12, 0, tzinfo=UTC)


def make_session() -> PairingSession:
    return PairingSession.create(
        bridge_id="bridge-01",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
        now=NOW,
    )


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
