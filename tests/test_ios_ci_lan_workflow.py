from __future__ import annotations

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).parents[1]
CODEMAGIC_YAML = REPO_ROOT / "codemagic.yaml"
IOS_CLOUD_BUILD_DOC = REPO_ROOT / "docs" / "ios-cloud-build.md"
TASK7_REPORT = (
    REPO_ROOT
    / "docs"
    / "superpowers"
    / "sdd"
    / "2026-08-28-jarvis-ios"
    / "task-7-report.md"
)


def test_unsigned_workflow_explicitly_gates_lan_protocol_transport_and_ui_tests() -> None:
    codemagic = yaml.safe_load(CODEMAGIC_YAML.read_text(encoding="utf-8"))
    workflow = codemagic["workflows"]["ios_unsigned"]
    scripts = workflow["scripts"]
    script_names = [step["name"] for step in scripts]

    package_step = "Run LAN protocol and transport Swift package tests"
    simulator_step = "Run unsigned simulator AppModel and conversation UI tests"

    assert package_step in script_names
    assert simulator_step in script_names

    package_script = scripts[script_names.index(package_step)]["script"]
    assert 'swift test --filter JarvisProtocolTests' in package_script
    assert 'swift test --filter JarvisCoreTests' in package_script

    simulator_script = scripts[script_names.index(simulator_step)]["script"]
    assert '-only-testing:JarvisIOSTests/AppModelTests' in simulator_script
    assert '-only-testing:JarvisIOSUITests/ConversationUITests' in simulator_script
    assert 'CODE_SIGNING_ALLOWED=NO' in simulator_script
    assert 'xcode-project junit-test-results' in simulator_script


def test_ios_cloud_build_doc_covers_lan_prereqs_pairing_limitations_and_evidence() -> None:
    doc = IOS_CLOUD_BUILD_DOC.read_text(encoding="utf-8")

    assert "same Wi-Fi" in doc
    assert "pairing" in doc
    assert "simulator" in doc
    assert "tests/test_lan_bridge.py -q" in doc
    assert "Codemagic build URL" in doc
    assert "XCResult" in doc
    assert "JUnit" in doc


def test_task7_report_states_lan_gate_is_still_cloud_pending_and_manual_testflight_only() -> None:
    report = TASK7_REPORT.read_text(encoding="utf-8")

    assert "cloud-validation-pending" in report
    assert "same Wi-Fi" in report
    assert "manual-only" in report
    assert "Codemagic build URL" in report
