from __future__ import annotations

from enum import IntEnum, StrEnum
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class RiskLevel(IntEnum):
    LOW = 10
    MEDIUM = 20
    FORBIDDEN = 90


class ActionStatus(StrEnum):
    PROPOSED = "proposed"
    AWAITING_CONFIRMATION = "awaiting_confirmation"
    EXECUTING = "executing"
    COMPLETED = "completed"
    FAILED = "failed"
    REJECTED = "rejected"
    CANCELLED = "cancelled"


class ToolProposal(StrictModel):
    tool_name: str = Field(min_length=1)
    arguments: dict[str, Any] = Field(default_factory=dict)
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)

    @field_validator("tool_name", mode="before")
    @classmethod
    def strip_tool_name(cls, value: object) -> object:
        return value.strip() if isinstance(value, str) else value


class ToolResult(StrictModel):
    ok: bool
    code: str = Field(min_length=1)
    message: str
    data: dict[str, Any] = Field(default_factory=dict)


class AssistantReply(StrictModel):
    text: str
    spoken_text: str | None = None
    proposal: ToolProposal | None = None
    provider: str


class Settings(StrictModel):
    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "qwen2.5:3b"
    openai_model: str = "gpt-5.4-mini"
    allowed_search_roots: list[Path] = Field(default_factory=list)
    always_on_top: bool = True
    click_through: bool = False
    sidebar_visible: bool = True
    microphone_name: str | None = None
    speaker_name: str | None = None
