from __future__ import annotations

import hmac
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any


class PairingClaimError(ValueError):
    """Raised when a pairing session cannot be claimed."""


@dataclass(frozen=True)
class PairedDevice:
    device_id: str
    display_name: str
    created_at: datetime
    last_seen_at: datetime
    revoked: bool
    secret: bytes = field(repr=False)


@dataclass
class PairingSession:
    bridge_id: str
    bridge_url: str
    certificate_sha256: str
    session_id: str
    expires_at: datetime
    proof: str = field(repr=False)
    _claimed: bool = field(default=False, init=False, repr=False)

    @classmethod
    def create(
        cls,
        *,
        bridge_id: str,
        bridge_url: str,
        certificate_sha256: str,
        now: datetime | None = None,
        ttl: timedelta = timedelta(seconds=120),
    ) -> PairingSession:
        created_at = _as_utc(now or datetime.now(UTC))
        if ttl <= timedelta(0):
            raise ValueError("pairing TTL must be positive")
        return cls(
            bridge_id=bridge_id,
            bridge_url=bridge_url,
            certificate_sha256=certificate_sha256,
            session_id=secrets.token_urlsafe(24),
            expires_at=created_at + ttl,
            proof=secrets.token_urlsafe(32),
        )

    @property
    def qr_payload(self) -> dict[str, Any]:
        return {
            "version": 1,
            "bridge_id": self.bridge_id,
            "bridge_url": self.bridge_url,
            "certificate_sha256": self.certificate_sha256,
            "session_id": self.session_id,
            "expires_at": self.expires_at.isoformat(),
            "proof": self.proof,
        }

    def claim(self, device_name: str, proof: str, now: datetime) -> PairedDevice:
        claimed_at = _as_utc(now)
        if not device_name.strip():
            raise PairingClaimError("device name must not be blank")
        if self._claimed:
            raise PairingClaimError("pairing session already claimed")
        if claimed_at >= self.expires_at:
            raise PairingClaimError("pairing session expired")
        if not isinstance(proof, str) or not hmac.compare_digest(
            self.proof.encode("utf-8"), proof.encode("utf-8")
        ):
            raise PairingClaimError("invalid proof")

        self._claimed = True
        return PairedDevice(
            device_id=secrets.token_urlsafe(32),
            display_name=device_name.strip(),
            created_at=claimed_at,
            last_seen_at=claimed_at,
            revoked=False,
            secret=secrets.token_bytes(32),
        )


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must be timezone-aware")
    return value.astimezone(UTC)
