# Task 5 Report — CI validation and cloud handoff

## Status

Task 5 is **configuration-complete / cloud-validation-pending** as of
September 2, 2026 (Asia/Shanghai). The unsigned Codemagic workflow now names
the iPhone LAN-control gates explicitly, and the handoff docs now describe the
same-Wi-Fi prerequisites, pairing flow, simulator limits, local desktop bridge
verification command, and the exact Codemagic evidence required before the
cloud gate can close.

No Codemagic run was started from this worktree. There is still no Codemagic
build URL, XCResult artifact, JUnit artifact, simulator pass result, signed
IPA, or TestFlight upload to claim.

## Files

- `codemagic.yaml`
- `docs/ios-cloud-build.md`
- `docs/superpowers/sdd/2026-08-28-jarvis-ios/task-7-report.md`
- `tests/test_ios_ci_lan_workflow.py`

## CI and handoff changes

- `ios_unsigned` now runs `swift test --filter JarvisProtocolTests`,
  `swift test --filter JarvisCoreTests`, and an unsigned simulator run limited
  to `JarvisIOSTests/AppModelTests` plus
  `JarvisIOSUITests/ConversationUITests`. TestFlight publishing remains absent
  from that workflow.
- `docs/ios-cloud-build.md` now documents the same-Wi-Fi-only scope, the
  one-time pairing prerequisite, why a hosted simulator cannot prove live LAN
  discovery/reachability, the local desktop bridge regression command
  `$env:PYTHONPATH='src'; py -3.12 -m pytest tests/test_lan_bridge.py -q`, and
  the exact Codemagic logs/artifacts required to close the cloud gate.
- `docs/superpowers/sdd/2026-08-28-jarvis-ios/task-7-report.md` now reflects
  the Task 5 LAN-control CI slice, the current local verification evidence, and
  the unchanged manual-only TestFlight policy.
- `tests/test_ios_ci_lan_workflow.py` statically locks the unsigned workflow
  and handoff docs to the LAN-control CI contract.

## Verification

All commands ran from
`C:\Users\Administrator\Documents\ChatGPT\工作项目\.worktrees\jarvis-ios`.

| Check | Result |
| --- | --- |
| RED: `py -3.12 -m pytest tests/test_ios_ci_lan_workflow.py -q` before edits | `3 failed`: the workflow/doc contract did not explicitly cover the LAN protocol, transport, UI, same-Wi-Fi prerequisites, simulator limits, bridge test command, or Codemagic evidence requirements. |
| GREEN: `py -3.12 -m pytest tests/test_ios_ci_lan_workflow.py -q` | `3 passed`. |
| `py -3.12 -m pytest tests/test_ios_ci_preflight.py tests/test_ios_ci_versioning.py -q` | `6 passed`. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest tests/test_lan_bridge.py -q` | `7 passed, 1 warning in 0.73s`. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp=.pytest-task5` | `209 passed, 1 warning in 18.35s`. |
| `py -3.12 -m ruff check src tests` | `All checks passed!`. |
| `bash -n scripts/ci/verify-ios-project.sh` and `bash -n scripts/ci/set-ios-version.sh` via Git Bash | Passed. |
| `xcodegen version` | Failed on this Windows host: command not found. |
| `swift --version` | Failed on this Windows host: command not found. |
| `xcodebuild -version` | Failed on this Windows host: command not found. |

## Remaining cloud gate

The dynamic gate is still open. A real Codemagic run must produce the build URL,
successful logs for XcodeGen, preflight, `JarvisProtocolTests`,
`JarvisCoreTests`, `AppModelTests`, and `ConversationUITests`, plus retained
`build/test-results/JarvisIOS.xcresult` and `build/test-results/junit/**/*.xml`
artifacts. If a signed build is later approved, TestFlight stays manual-only
and requires `submit_to_testflight: true`; nothing in Task 5 changed that.
