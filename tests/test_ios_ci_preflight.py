from __future__ import annotations

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parents[1]
PREFLIGHT = REPO_ROOT / "scripts" / "ci" / "verify-ios-project.sh"


def _bash() -> str:
    candidates = [
        os.environ.get("GIT_BASH"),
        r"C:\Program Files\Git\bin\bash.exe",
        shutil.which("bash"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    pytest.skip("A working Bash executable is required for CI preflight tests.")


def _scheme_xml(*, testable_names: tuple[str, ...]) -> str:
    testables = "\n".join(
        textwrap.dedent(
            f"""
            <TestableReference skipped="NO">
              <BuildableReference
                BuildableIdentifier="primary"
                BlueprintIdentifier="fixture-{name}"
                BuildableName="{name}.xctest"
                BlueprintName="{name}"
                ReferencedContainer="container:JarvisIOS.xcodeproj">
              </BuildableReference>
            </TestableReference>
            """
        ).strip()
        for name in testable_names
    )
    return textwrap.dedent(
        f"""\
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
          <BuildAction parallelizeBuildables="YES">
            <BuildActionEntries>
              <BuildActionEntry>
                <BuildableReference BlueprintName="JarvisIOSUITests" />
              </BuildActionEntry>
            </BuildActionEntries>
          </BuildAction>
          <TestAction buildConfiguration="Debug">
            <Testables>
        {textwrap.indent(testables, "      ")}
            </Testables>
          </TestAction>
        </Scheme>
        """
    )


def _xcodebuild_stub(bundle_ids: dict[str, str]) -> str:
    cases = "\n".join(
        f"  {target}) bundle_id='{bundle_id}' ;;"
        for target, bundle_id in bundle_ids.items()
    )
    return f"""#!/usr/bin/env bash
set -u
if [ "$1" = "-list" ]; then
  cat <<'EOF'
Information about project "JarvisIOS":
    Targets:
        JarvisIOS
        JarvisWidget
        JarvisIOSTests
        JarvisIOSUITests

    Build Configurations:
        Debug
        Release

    Schemes:
        JarvisIOS
EOF
  exit 0
fi

target=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-target" ]; then
    shift
    target="$1"
  fi
  shift
done

case "$target" in
{cases}
  *) printf 'unknown target: %s\\n' "$target" >&2; exit 2 ;;
esac
printf '    PRODUCT_BUNDLE_IDENTIFIER = %s\\n' "$bundle_id"
"""


def _run_preflight(
    tmp_path: Path,
    *,
    testable_names: tuple[str, ...] = ("JarvisIOSTests", "JarvisIOSUITests"),
    bundle_ids: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    if bundle_ids is None:
        bundle_ids = {
            "JarvisIOS": "com.jarvisassistant.ios",
            "JarvisWidget": "com.jarvisassistant.ios.widget",
            "JarvisIOSTests": "com.jarvisassistant.ios-tests",
            "JarvisIOSUITests": "com.jarvisassistant.ios-uitests",
        }

    project = tmp_path / "JarvisIOS.xcodeproj"
    scheme = project / "xcshareddata" / "xcschemes" / "JarvisIOS.xcscheme"
    scheme.parent.mkdir(parents=True)
    scheme.write_text(_scheme_xml(testable_names=testable_names), encoding="utf-8")
    (project / "project.pbxproj").write_text(
        "\n".join(
            f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};"
            for bundle_id in bundle_ids.values()
        ),
        encoding="utf-8",
    )

    xcodebuild = tmp_path / "xcodebuild"
    xcodebuild.write_text(_xcodebuild_stub(bundle_ids), encoding="utf-8", newline="\n")
    xcodebuild.chmod(0o755)

    env = os.environ.copy()
    env["XCODE_PROJECT"] = project.as_posix()
    env["XCODEBUILD_BIN"] = xcodebuild.as_posix()
    env["PATH"] = f"{tmp_path.as_posix()}:{env['PATH']}"
    return subprocess.run(
        [_bash(), PREFLIGHT.as_posix()],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_preflight_rejects_expected_test_target_outside_scheme_testables(
    tmp_path: Path,
) -> None:
    result = _run_preflight(tmp_path, testable_names=("JarvisIOSTests", "JarvisIOS"))

    assert result.returncode == 1
    assert "JarvisIOSUITests" in result.stderr
    assert "TestAction/Testables" in result.stderr


def test_preflight_rejects_bundle_ids_assigned_to_wrong_targets(tmp_path: Path) -> None:
    result = _run_preflight(
        tmp_path,
        bundle_ids={
            "JarvisIOS": "com.jarvisassistant.ios.widget",
            "JarvisWidget": "com.jarvisassistant.ios",
            "JarvisIOSTests": "com.jarvisassistant.ios-tests",
            "JarvisIOSUITests": "com.jarvisassistant.ios-uitests",
        },
    )

    assert result.returncode == 1
    assert "target 'JarvisIOS'" in result.stderr
    assert "expected 'com.jarvisassistant.ios'" in result.stderr
    assert "target 'JarvisWidget'" in result.stderr
    assert "expected 'com.jarvisassistant.ios.widget'" in result.stderr
