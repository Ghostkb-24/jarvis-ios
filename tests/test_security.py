from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.security import DecisionKind, SecurityPolicy
from jarvis_assistant.tools import default_registry


def test_clipboard_write_requires_confirmation_without_exposing_text() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(
        ToolProposal(
            tool_name="clipboard",
            arguments={"operation": "write", "text": "private-message"},
        )
    )
    assert decision.kind is DecisionKind.REQUIRE_CONFIRMATION
    assert "private-message" not in decision.summary


def test_clipboard_read_executes_automatically() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(
        ToolProposal(tool_name="clipboard", arguments={"operation": "read"})
    )
    assert decision.kind is DecisionKind.AUTO_EXECUTE


def test_unregistered_tool_is_rejected() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(ToolProposal(tool_name="delete_file", arguments={"path": "x"}))
    assert decision.kind is DecisionKind.REJECT


def test_invalid_arguments_are_rejected_before_execution() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(
        ToolProposal(tool_name="set_volume", arguments={"percent": 999})
    )
    assert decision.kind is DecisionKind.REJECT
    assert decision.code == "invalid_arguments"


def test_wechat_message_requires_confirmation_with_recipient_and_message_preview() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(
        ToolProposal(
            tool_name="send_wechat_message",
            arguments={"contact": "Ghost（小号）", "message": "今晚八点见"},
        )
    )

    assert decision.kind is DecisionKind.REQUIRE_CONFIRMATION
    assert "Ghost（小号）" in decision.summary
    assert "今晚八点见" in decision.summary
