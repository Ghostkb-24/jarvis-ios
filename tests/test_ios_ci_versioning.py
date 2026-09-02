from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).parents[1]
PROJECT_YML = REPO_ROOT / "ios" / "project.yml"
CODEMAGIC_YAML = REPO_ROOT / "codemagic.yaml"
VERSION_SCRIPT = REPO_ROOT / "scripts" / "ci" / "set-ios-version.sh"


@dataclass(frozen=True)
class ScriptResult:
    returncode: int
    stdout: str
    stderr: str
    call_log: str


def _bash() -> str:
    candidates = [
        os.environ.get("GIT_BASH"),
        r"C:\Program Files\Git\bin\bash.exe",
        shutil.which("bash"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    pytest.skip("A working Bash executable is required for CI versioning tests.")


def _run_version_script(
    tmp_path: Path,
    *,
    widget_build_number: str = "42",
) -> ScriptResult:
    ios_dir = tmp_path / "ios"
    project = ios_dir / "JarvisIOS.xcodeproj"
    project.mkdir(parents=True)
    (project / "project.pbxproj").write_text("fixture", encoding="utf-8")

    xcrun = tmp_path / "xcrun"
    xcrun.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n",
        encoding="utf-8",
        newline="\n",
    )
    xcrun.chmod(0o755)

    xcodebuild = tmp_path / "xcodebuild"
    xcodebuild.write_text(
        f"""#!/usr/bin/env bash
target=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-target" ]; then
    shift
    target="$1"
  fi
  shift
done
printf 'show-build-settings %s\\n' "$target" >> "$CALL_LOG"
printf '    MARKETING_VERSION = 2.3.4\\n'
if [ "$target" = "JarvisWidget" ]; then
  printf '    CURRENT_PROJECT_VERSION = {widget_build_number}\\n'
else
  printf '    CURRENT_PROJECT_VERSION = 42\\n'
fi
""",
        encoding="utf-8",
        newline="\n",
    )
    xcodebuild.chmod(0o755)

    call_log = tmp_path / "calls.log"
    env = os.environ.copy()
    env.update(
        {
            "BUILD_NUMBER": "42",
            "MARKETING_VERSION": "2.3.4",
            "IOS_PROJECT_DIR": ios_dir.as_posix(),
            "XCRUN_BIN": xcrun.as_posix(),
            "XCODEBUILD_BIN": xcodebuild.as_posix(),
            "CALL_LOG": call_log.as_posix(),
        }
    )
    result = subprocess.run(
        [_bash(), VERSION_SCRIPT.as_posix()],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return ScriptResult(
        returncode=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
        call_log=call_log.read_text(encoding="utf-8") if call_log.exists() else "",
    )


def test_project_uses_shared_xcode_version_build_settings() -> None:
    project = yaml.safe_load(PROJECT_YML.read_text(encoding="utf-8"))

    assert project["settings"]["base"]["MARKETING_VERSION"] == "1.0.0"
    assert project["settings"]["base"]["CURRENT_PROJECT_VERSION"] == "1"
    assert project["settings"]["base"]["VERSIONING_SYSTEM"] == "apple-generic"
    for target in ("JarvisIOS", "JarvisWidget"):
        properties = project["targets"][target]["info"]["properties"]
        assert properties["CFBundleShortVersionString"] == "$(MARKETING_VERSION)"
        assert properties["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"


def test_signed_version_script_applies_one_build_number_to_app_and_widget(
    tmp_path: Path,
) -> None:
    result = _run_version_script(tmp_path)

    assert result.returncode == 0, result.stderr
    assert result.call_log.splitlines() == [
        "agvtool new-marketing-version 2.3.4",
        "agvtool new-version -all 42",
        "show-build-settings JarvisIOS",
        "show-build-settings JarvisWidget",
    ]


def test_signed_version_script_rejects_widget_build_number_drift(tmp_path: Path) -> None:
    result = _run_version_script(tmp_path, widget_build_number="41")

    assert result.returncode == 1
    assert "JarvisWidget" in result.stderr
    assert "CURRENT_PROJECT_VERSION" in result.stderr
    assert "expected '42'" in result.stderr


def test_testflight_workflow_versions_both_targets_before_archive() -> None:
    codemagic = yaml.safe_load(CODEMAGIC_YAML.read_text(encoding="utf-8"))
    workflow = codemagic["workflows"]["ios_testflight"]

    assert workflow["environment"]["vars"]["MARKETING_VERSION"] == "1.0.0"
    assert workflow["environment"]["ios_signing"]["bundle_identifier"] == (
        "com.jarvisassistant.ios*"
    )
    script_names = [step["name"] for step in workflow["scripts"]]
    version_index = script_names.index("Set and verify shared app and widget version")
    archive_index = script_names.index("Build signed IPA for TestFlight")
    assert version_index < archive_index
    assert workflow["scripts"][version_index]["script"].strip() == (
        'bash "$CM_BUILD_DIR/scripts/ci/set-ios-version.sh"'
    )
