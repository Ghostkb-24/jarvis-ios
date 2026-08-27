from __future__ import annotations

import hashlib
import hmac
from datetime import UTC, datetime

from jarvis_assistant.bridge.protocol import BridgeRequest


class AuthenticationError(ValueError):
    pass


def sign_request(secret: bytes, request: BridgeRequest) -> str:
    return hmac.new(secret, request.canonical_bytes(), hashlib.sha256).hexdigest()


def verify_request(
    secret: bytes,
    request: BridgeRequest,
    signature: str,
    now: datetime,
) -> None:
    expected_signature = sign_request(secret, request)
    if not hmac.compare_digest(expected_signature, signature):
        raise AuthenticationError("invalid signature")

    issued_at = _parse_utc_timestamp(request.issued_at)
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    age_seconds = (now.astimezone(UTC) - issued_at).total_seconds()
    if age_seconds > 300:
        raise AuthenticationError("request expired")
    if age_seconds < -30:
        raise AuthenticationError("request timestamp is too far in the future")


def _parse_utc_timestamp(value: str) -> datetime:
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError as error:
        raise AuthenticationError("invalid timestamp") from error
    if timestamp.tzinfo is None or timestamp.utcoffset() != UTC.utcoffset(None):
        raise AuthenticationError("invalid timestamp")
    return timestamp.astimezone(UTC)
