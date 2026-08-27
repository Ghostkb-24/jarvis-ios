from __future__ import annotations

import json
from enum import StrEnum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class TaskState(StrEnum):
    PREPARING = "preparing"
    AWAITING_CONFIRMATION = "awaiting_confirmation"
    EXECUTING = "executing"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    RESULT_UNKNOWN = "result_unknown"


class Risk(StrEnum):
    LOW = "low"
    CONFIRMATION_REQUIRED = "confirmation_required"


class BridgeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    version: Literal[1]
    request_id: str = Field(min_length=1)
    device_id: str = Field(min_length=1)
    issued_at: str
    idempotency_key: str = Field(min_length=1)
    kind: Literal["chat", "tool", "confirm", "cancel"]
    payload: dict[str, Any]

    def canonical_bytes(self) -> bytes:
        return json.dumps(
            self.model_dump(),
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")


class BridgeResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    version: Literal[1]
    request_id: str = Field(min_length=1)
    state: TaskState
    risk: Risk
    payload: dict[str, Any]
