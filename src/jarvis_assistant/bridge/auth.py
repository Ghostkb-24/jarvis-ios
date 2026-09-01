from __future__ import annotations

import hashlib
import hmac
from datetime import UTC, datetime

from jarvis_assistant.bridge.protocol import (
    BridgeRequest,
    TaskConfirmation,
    canonical_confirmation_bytes,
)


class AuthenticationError(ValueError):
    pass


def sign_request(secret: bytes, request: BridgeRequest) -> str:
    return hmac.new(secret, request.canonical_bytes(), hashlib.sha256).hexdigest()


def sign_confirmation(
    secret: bytes,
    request: BridgeRequest,
    confirmation: TaskConfirmation,
) -> str:
    return hmac.new(
        secret,
        canonical_confirmation_bytes(request, confirmation),
        hashlib.sha256,
    ).hexdigest()


def verify_request(
    secret: bytes,
    request: BridgeRequest,
    signature: str,
    now: datetime,
    confirmation: TaskConfirmation | None = None,
) -> None:
    expected_signature = (
        sign_confirmation(secret, request, confirmation)
        if confirmation is not None
        else sign_request(secret, request)
    )
    if not _is_lowercase_hex_signature(signature, len(expected_signature)):
        raise AuthenticationError("invalid signature")
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
    if confirmation is not None:
        confirmation_age_seconds = (
            now.astimezone(UTC) - _parse_utc_timestamp(confirmation.decided_at)
        ).total_seconds()
        if confirmation_age_seconds > 300:
            raise AuthenticationError("confirmation expired")
        if confirmation_age_seconds < -30:
            raise AuthenticationError("confirmation timestamp is too far in the future")


def _parse_utc_timestamp(value: str) -> datetime:
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError as error:
        raise AuthenticationError("invalid timestamp") from error
    if timestamp.tzinfo is None or timestamp.utcoffset() != UTC.utcoffset(None):
        raise AuthenticationError("invalid timestamp")
    return timestamp.astimezone(UTC)


def _is_lowercase_hex_signature(value: object, expected_length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == expected_length
        and value.isascii()
        and all(character in "0123456789abcdef" for character in value)
    )
