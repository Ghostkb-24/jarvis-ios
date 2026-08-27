from pydantic import ValidationError

from jarvis_assistant.domain import RiskLevel, ToolProposal


def test_tool_proposal_rejects_blank_tool_name() -> None:
    try:
        ToolProposal(tool_name=" ", arguments={})
    except ValidationError:
        return
    raise AssertionError("blank tool name must fail validation")


def test_risk_levels_have_explicit_order() -> None:
    assert RiskLevel.LOW.value == 10
    assert RiskLevel.MEDIUM.value == 20
    assert RiskLevel.FORBIDDEN.value == 90
