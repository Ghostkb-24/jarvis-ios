from __future__ import annotations

import json
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, ValidationError

from jarvis_assistant.domain import RiskLevel, ToolProposal
from jarvis_assistant.storage import redact_value
from jarvis_assistant.tools import ClipboardInput, ToolRegistry


class DecisionKind(StrEnum):
    AUTO_EXECUTE = "auto_execute"
    REQUIRE_CONFIRMATION = "require_confirmation"
    REJECT = "reject"


class SecurityDecision(BaseModel):
    model_config = ConfigDict(frozen=True)

    kind: DecisionKind
    code: str
    summary: str


class SecurityPolicy:
    def __init__(self, registry: ToolRegistry) -> None:
        self._registry = registry

    def evaluate(self, proposal: ToolProposal) -> SecurityDecision:
        try:
            spec = self._registry.get(proposal.tool_name)
            arguments = self._registry.validate(proposal)
        except KeyError:
            return SecurityDecision(
                kind=DecisionKind.REJECT,
                code="tool_not_allowed",
                summary="该操作不在允许的工具列表中。",
            )
        except ValidationError:
            return SecurityDecision(
                kind=DecisionKind.REJECT,
                code="invalid_arguments",
                summary="工具参数无效，操作已拒绝。",
            )

        if spec.risk is RiskLevel.FORBIDDEN:
            return SecurityDecision(
                kind=DecisionKind.REJECT,
                code="forbidden",
                summary="该操作在当前版本中被禁止。",
            )

        if isinstance(arguments, ClipboardInput) and arguments.operation == "read":
            return SecurityDecision(
                kind=DecisionKind.AUTO_EXECUTE,
                code="allowed",
                summary="读取剪贴板内容。",
            )

        summary = _summarize(proposal)
        if spec.risk is RiskLevel.MEDIUM:
            return SecurityDecision(
                kind=DecisionKind.REQUIRE_CONFIRMATION,
                code="confirmation_required",
                summary=summary,
            )
        return SecurityDecision(
            kind=DecisionKind.AUTO_EXECUTE,
            code="allowed",
            summary=summary,
        )


def _summarize(proposal: ToolProposal) -> str:
    if proposal.tool_name == "clipboard":
        return "将模型提供的文本写入剪贴板（内容已隐藏）。"
    if proposal.tool_name == "send_wechat_message":
        contact = str(proposal.arguments.get("contact", ""))
        message = str(proposal.arguments.get("message", ""))
        return f"准备向微信联系人“{contact}”发送：\n{message}"
    safe_arguments = redact_value(proposal.arguments)
    compact = json.dumps(safe_arguments, ensure_ascii=False, sort_keys=True)
    return f"执行 {proposal.tool_name}：{compact}"
