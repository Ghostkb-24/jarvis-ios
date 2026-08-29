# Task 7 Report — Codemagic unsigned build and TestFlight handoff

## Status

Task 7 is **configuration-complete / cloud-validation-pending**. The
repository now has an Apple Silicon Codemagic unsigned test workflow, a
post-XcodeGen preflight, retained XCResult/JUnit artifacts, and a manual-only
TestFlight workflow. No Codemagic build has been started from this worktree.
There is no cloud build URL, artifact, signed IPA, Swift pass, simulator pass,
or TestFlight upload to claim.

The dynamic Codemagic gate remains open. It closes only after the unsigned
`ios_unsigned` workflow runs on Codemagic and proves all of the following on
macOS: XcodeGen generates the project, the post-generation preflight passes,
`cd ios && swift test` passes, and the unsigned `xcodebuild test` simulator run
passes while producing the listed XCResult and JUnit artifacts. Until then,
Tasks 4–6 remain cloud-validation-pending.

## Files

- `codemagic.yaml`
- `scripts/ci/verify-ios-project.sh`
- `docs/ios-cloud-build.md`
- `.gitignore`
- `docs/superpowers/sdd/2026-08-28-jarvis-ios/task-7-report.md`

No Task 8 integration test, acceptance checklist, README change, source
feature, credential, certificate, provisioning profile, or private API key was
added. The SDD ledger was not modified.

## CI behavior and safety controls

- `ios_unsigned` runs on `mac_mini_m2`, installs XcodeGen, generates the
  project, runs the preflight, runs `swift test`, and runs the `JarvisIOS`
  simulator scheme with `CODE_SIGNING_ALLOWED=NO`,
  `CODE_SIGNING_REQUIRED=NO`, and an empty code-sign identity. It has no
  signing integration, provisioning command, IPA artifact, or publishing step.
- The unsigned simulator step writes
  `build/test-results/JarvisIOS.xcresult`, then calls Codemagic's
  `xcode-project junit-test-results` to emit JUnit XML. Both result forms are
  configured as artifacts, and the JUnit path is registered as a Codemagic test
  report.
- `verify-ios-project.sh` accepts `PROJECT_YML` and `XCODE_PROJECT` overrides
  solely to make failure conditions testable without editing the repository. It
  aggregates actionable errors for the manifest, four required targets, scheme,
  four bundle IDs, and two scheme test targets. When source configuration is
  complete it requires the generated Xcode project, uses `xcodebuild -list` to
  verify generated targets/scheme, and confirms that the bundle IDs reached the
  generated `project.pbxproj`.
- `ios_testflight` is manual-only and defaults its Codemagic Boolean input
  `submit_to_testflight` to `false`. The workflow is skipped unless it is
  explicitly started with `submit_to_testflight: true`; its first script also
  rejects any other value. Only that opt-in workflow references the named
  App Store Connect integration (`jarvis_app_store_connect`), uses Codemagic
  managed App Store signing, builds an IPA, and allows TestFlight publishing to
  the `Jarvis Internal` group.
- `.gitignore` now excludes generated Xcode projects, iOS build/DerivedData,
  XCResult/IPA/dSYM output, and common local signing exports. It does not ignore
  `ios/project.yml`, Swift source, package files, or tests.

## Test-first and local verification evidence

All commands ran from
`C:\Users\Administrator\Documents\ChatGPT\工作项目\.worktrees\jarvis-ios`.

| Check | Result |
| --- | --- |
| RED: `PROJECT_YML=/tmp/jarvis-task7-missing/project.yml bash scripts/ci/verify-ios-project.sh` through Git Bash | Exit 1. It printed exactly one actionable error naming the missing XcodeGen manifest, then `iOS project preflight failed with 1 actionable error(s).` |
| `bash -n scripts/ci/verify-ios-project.sh` through Git Bash | Passed (exit 0). |
| Normal preflight before XcodeGen | Exit 1, as required: generated `ios/JarvisIOS.xcodeproj` is missing and the script tells the operator to run `cd ios && xcodegen generate`. |
| Python YAML/static contract check for `codemagic.yaml` | Passed: parsed YAML; verified Apple Silicon instance, disabled TestFlight input, explicit input gate/integration, unsigned code-sign flags, and JUnit conversion. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp=<task7-temp>` | `185 passed in 15.55s`. |
| `py -3.12 -m ruff check src tests` | `All checks passed!`. |
| Git integrity | `git diff --cached --check` passed before commit; `git show --check --oneline --stat` passed for the Task 7 commit. |

## Host limitations and cloud gate

The Windows host cannot execute the required Apple build tools. Direct attempts
to run `xcodegen generate`, `xcodebuild -version`, and `swift --version` each
reported that the command is not recognized. `C:\Windows\System32\bash.exe`
also failed before launching WSL with `Bash/Service/CreateInstance/E_ACCESSDENIED`.
Git Bash is available and was used only for the shell syntax and RED/preflight
checks above; it cannot replace Xcode or Codemagic macOS validation.

`docs/ios-cloud-build.md` contains the exact account handoff: Apple Developer
membership, App ID/App Store Connect record, dedicated App Manager API key in
the encrypted Codemagic integration, managed signing, internal TestFlight
group, and the explicit opt-in run. The actual build URL and artifact names
must be recorded only after a real Codemagic run completes.
