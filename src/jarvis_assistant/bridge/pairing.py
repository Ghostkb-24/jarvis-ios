from __future__ import annotations

import hmac
import ipaddress
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from threading import Lock
from typing import Any
from urllib.parse import urlsplit

_PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in (
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
    )
)


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
    _claim_lock: Lock = field(default_factory=Lock, init=False, repr=False)

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
        bridge_url = _validate_bridge_url(bridge_url)
        if not _is_lowercase_sha256(certificate_sha256):
            raise ValueError("certificate fingerprint must be 64 lowercase hexadecimal characters")
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
        if claimed_at >= self.expires_at:
            raise PairingClaimError("pairing session expired")
        if not isinstance(proof, str) or not hmac.compare_digest(
            self.proof.encode("utf-8"), proof.encode("utf-8")
        ):
            raise PairingClaimError("invalid proof")

        with self._claim_lock:
            if self._claimed:
                raise PairingClaimError("pairing session already claimed")
            device = PairedDevice(
                device_id=secrets.token_urlsafe(32),
                display_name=device_name.strip(),
                created_at=claimed_at,
                last_seen_at=claimed_at,
                revoked=False,
                secret=secrets.token_bytes(32),
            )
            self._claimed = True
            return device


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must be timezone-aware")
    return value.astimezone(UTC)


def is_private_bridge_host(host: str) -> bool:
    normalized = canonicalize_bridge_host(host)
    try:
        address = ipaddress.ip_address(normalized)
    except ValueError:
        if _is_legacy_numeric_host(normalized):
            return False
        return bool(normalized) and (
            normalized == "localhost" or normalized.endswith(".local") or "." not in normalized
        )
    return any(address in network for network in _PRIVATE_NETWORKS)


def canonicalize_bridge_host(host: str) -> str:
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        return host.rstrip(".").casefold()


def _is_legacy_numeric_host(host: str) -> bool:
    if host.isdecimal():
        return True
    return (
        host.startswith("0x")
        and len(host) > 2
        and all(character in "0123456789abcdef" for character in host[2:])
    )


def _validate_bridge_url(value: str) -> str:
    try:
        parsed = urlsplit(value)
        host = parsed.hostname
        port = parsed.port
    except ValueError as error:
        raise ValueError("bridge URL must be a private HTTPS URL") from error
    if (
        parsed.scheme.casefold() != "https"
        or host is None
        or parsed.username is not None
        or parsed.password is not None
        or not is_private_bridge_host(host)
    ):
        raise ValueError("bridge URL must be a private HTTPS URL")
    canonical_host = canonicalize_bridge_host(host)
    url_host = f"[{canonical_host}]" if ":" in canonical_host else canonical_host
    netloc = f"{url_host}:{port}" if port is not None else url_host
    return parsed._replace(netloc=netloc).geturl()


def _is_lowercase_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and value.isascii()
        and all(character in "0123456789abcdef" for character in value)
    )
