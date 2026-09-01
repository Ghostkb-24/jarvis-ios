# Task 7 Report — Codemagic unsigned build and TestFlight handoff

## Status

Task 7 is **configuration-complete / cloud-validation-pending** after static
review round 1. The repository has an Apple Silicon Codemagic unsigned test
workflow, an exact post-XcodeGen preflight, retained XCResult/JUnit artifacts,
and a manual-only TestFlight workflow with shared app/Widget versioning. No
Codemagic build has been started from this worktree.
There is no cloud build URL, artifact, signed IPA, Swift pass, simulator pass,
or TestFlight upload to claim.
That pending gate now explicitly includes the September 1, 2026 same Wi-Fi
iPhone LAN-control coverage: protocol, transport, AppModel, and conversation
UI checks are configured, but no hosted macOS run has executed them yet.

The dynamic Codemagic gate remains open. It closes only after the unsigned
`ios_unsigned` workflow runs on Codemagic and proves all of the following on
macOS: XcodeGen generates the project, the post-generation preflight passes,
`cd ios && swift test` passes, and the unsigned `xcodebuild test` simulator run
passes while producing the listed XCResult and JUnit artifacts. Until then,
Tasks 4–6 remain cloud-validation-pending.

## Files

- `codemagic.yaml`
- `scripts/ci/verify-ios-project.sh`
- `scripts/ci/set-ios-version.sh`
- `ios/project.yml`
- `docs/ios-cloud-build.md`
- `tests/test_ios_ci_preflight.py`
- `tests/test_ios_ci_versioning.py`
- `.gitignore`
- `docs/superpowers/sdd/2026-08-28-jarvis-ios/task-7-report.md`

No Task 8 integration test, acceptance checklist, README change, source
feature, credential, certificate, provisioning profile, or private API key was
added. The SDD ledger was not modified.

## CI behavior and safety controls

- `ios_unsigned` runs on `mac_mini_m2`, installs XcodeGen, generates the
  project, runs the preflight, runs
  `swift test --filter JarvisProtocolTests`, runs
  `swift test --filter JarvisCoreTests`, and runs the `JarvisIOS` simulator
  scheme with `-only-testing:JarvisIOSTests/AppModelTests`,
  `-only-testing:JarvisIOSUITests/ConversationUITests`,
  `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, and an empty
  code-sign identity. It has no signing integration, provisioning command, IPA
  artifact, or publishing step.
- The unsigned simulator step writes
  `build/test-results/JarvisIOS.xcresult`, then calls Codemagic's
  `xcode-project junit-test-results` to emit JUnit XML. Both result forms are
  configured as artifacts, and the JUnit path is registered as a Codemagic test
  report. The explicit LAN slice is: protocol wire-contract checks in
  `JarvisProtocolTests`, pairing/transport client checks in `JarvisCoreTests`,
  and AppModel plus confirmation UI coverage in the simulator run.
- `verify-ios-project.sh` accepts `PROJECT_YML`, `XCODE_PROJECT`,
  `XCODE_SCHEME`, and `XCODEBUILD_BIN` overrides solely to make failure
  conditions testable without editing the repository or requiring Xcode on the
  Windows host. It parses the generated shared scheme's
  `TestAction/Testables`, requires exactly one `BlueprintName` for each of
  `JarvisIOSTests` and `JarvisIOSUITests`, and rejects unrelated testables. It
  uses `xcodebuild -list` for the generated target/scheme inventory and
  `xcodebuild -showBuildSettings -target` for each target's exact
  `PRODUCT_BUNDLE_IDENTIFIER`; global string presence no longer passes.
- `ios_testflight` is manual-only and defaults its Codemagic Boolean input
  `submit_to_testflight` to `false`. The workflow is skipped unless it is
  explicitly started with `submit_to_testflight: true`; its first script also
  rejects any other value. Only that opt-in workflow references the named
  App Store Connect integration (`jarvis_app_store_connect`), uses Codemagic
  managed App Store signing, builds an IPA, and allows TestFlight publishing to
  the `Jarvis Internal` group. Task 5 keeps TestFlight manual-only; the LAN
  control validation work did not add any automatic publish path.
- The signed workflow's managed-signing bundle filter is
  `com.jarvisassistant.ios*`, covering the exact main app and Widget extension
  App IDs. The handoff requires the shared
  `group.com.jarvisassistant.shared` capability on both explicit App IDs, an
  Apple Distribution certificate, and separate App Store distribution
  provisioning profiles for `com.jarvisassistant.ios` and
  `com.jarvisassistant.ios.widget`. Signing material remains external.
- `ios/project.yml` defines `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`, and `VERSIONING_SYSTEM: apple-generic`; both app
  and Widget Info.plists resolve their short version/build number from those
  variables. Before archive, `set-ios-version.sh` maps the approved marketing
  version and Codemagic's positive `BUILD_NUMBER` through `agvtool ... -all`,
  then validates Release build settings for both `JarvisIOS` and
  `JarvisWidget`. Any drift fails the signed workflow before archive/upload.
- `.gitignore` now excludes generated Xcode projects, iOS build/DerivedData,
  XCResult/IPA/dSYM output, and common local signing exports. It does not ignore
  `ios/project.yml`, Swift source, package files, or tests.

## Test-first and local verification evidence

All commands ran from
`C:\Users\Administrator\Documents\ChatGPT\工作项目\.worktrees\jarvis-ios`.

| Check | Result |
| --- | --- |
| RED: `PROJECT_YML=/tmp/jarvis-task7-missing/project.yml bash scripts/ci/verify-ios-project.sh` through Git Bash | Exit 1. It printed exactly one actionable error naming the missing XcodeGen manifest, then `iOS project preflight failed with 1 actionable error(s).` |
| RED: `py -3.12 -m pytest tests/test_ios_ci_preflight.py -q` before the fix | `2 failed`: the old preflight incorrectly returned exit 0 for a generated scheme with the UI test only in `BuildAction`, and for swapped app/Widget bundle IDs. |
| GREEN: `py -3.12 -m pytest tests/test_ios_ci_preflight.py -q` | `2 passed`; the real shell script was exercised with isolated generated-project and `xcodebuild` fixtures. |
| RED: `py -3.12 -m pytest tests/test_ios_ci_versioning.py -q` before the fix | `3 failed`: shared Xcode version settings and the signed version script did not exist. A fourth focused workflow test then failed because signed YAML had no version environment/stage. |
| GREEN: `py -3.12 -m pytest tests/test_ios_ci_versioning.py -q` | `4 passed`, including app/Widget version equality, target-specific drift failure, and signed-workflow ordering. |
| RED: `py -3.12 -m pytest tests/test_ios_ci_lan_workflow.py -q` before the Task 5 update | `3 failed`: the unsigned workflow did not explicitly name the LAN protocol/transport/UI gates, and the handoff docs omitted same Wi-Fi prerequisites, simulator limits, the local bridge regression command, and required Codemagic evidence. |
| GREEN: `py -3.12 -m pytest tests/test_ios_ci_lan_workflow.py -q` | `3 passed`; it statically verifies the unsigned workflow's LAN slices plus the cloud-handoff documentation contract. |
| `bash -n scripts/ci/verify-ios-project.sh` and `bash -n scripts/ci/set-ios-version.sh` through Git Bash | Passed (exit 0). |
| Normal preflight before XcodeGen | Exit 1, as required: generated `ios/JarvisIOS.xcodeproj` is missing and the script tells the operator to run `cd ios && xcodegen generate`. |
| Python YAML/static contract check for `codemagic.yaml` and `ios/project.yml` | Both parsed as mappings; pytest also verifies signed version stage/order, bundle filter, shared Xcode version variables, disabled-by-default TestFlight gate, and app/Widget Info.plist variable use. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest tests/test_lan_bridge.py -q` | `7 passed, 1 warning in 0.73s`. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp=<task7-temp>` | `209 passed, 1 warning in 18.35s`. |
| `py -3.12 -m ruff check src tests` | `All checks passed!`. |
| Git integrity | `git diff --check`, `git diff --cached --check`, and post-commit `git show --check --oneline --stat` passed. |

## Host limitations and cloud gate

The Windows host cannot execute the required Apple build tools. Direct attempts
to run `xcodegen generate`, `xcodebuild -version`, and `swift --version` each
reported that the command is not recognized. `C:\Windows\System32\bash.exe`
also failed before launching WSL with `Bash/Service/CreateInstance/E_ACCESSDENIED`.
Git Bash is available and was used for shell syntax and test-double-backed
preflight/version checks; it cannot replace Xcode or Codemagic macOS
validation. The exact `xcodebuild`, `xcrun agvtool`, managed-profile assignment,
archive, IPA, and upload paths remain unexecuted locally.
The same limitation applies to same-Wi-Fi pairing and live bridge reachability:
this Windows host can run the Python LAN bridge tests, but it cannot prove the
hosted simulator's network path to a real desktop bridge or Bonjour discovery.

`docs/ios-cloud-build.md` contains the exact account handoff: Apple Developer
membership, main and Widget explicit App IDs, shared App Group, two App Store
distribution profiles, Apple Distribution certificate, App Store Connect app
record, dedicated App Manager API key in the encrypted Codemagic integration,
managed signing, unique Codemagic build number, internal TestFlight group, the
explicit opt-in run, the local Python bridge regression command, same Wi-Fi
pairing prerequisites, simulator limitations, and the exact Codemagic build URL
plus artifact evidence required before closing the cloud gate. The actual build
URL and artifact names must be recorded only after a real Codemagic run
completes.
