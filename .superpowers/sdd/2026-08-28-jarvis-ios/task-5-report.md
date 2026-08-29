# Task 5 Report — SwiftUI Extreme-Night Conversation UI

## Status

Task 5 is **implementation-ready / cloud-validation-pending**. The approved
A-layout source, deterministic UI-test fixtures, and five required UI tests are
implemented. Static-review round 1 also adds six AppModel unit tests and the
state/ownership controls they specify. Static-review round 2 removes the
Swift-6-incompatible class-level `@MainActor` annotation from `XCTestCase` and
applies it only to the six tests and the two AppModel-state helpers that need
it; the controllable Bridge remains a non-main-actor `actor`. Static-review
round 3 also locally isolates the four async XCTest helpers that participate in
AppModel-state waiting, avoiding a non-Sendable XCTestCase crossing an async
boundary. This Windows host has neither XcodeGen nor Xcode, so no local Swift
compile, simulator run, or test pass is claimed.

Implementation commit:
`8bd7fc8f134c5035b60c2e561a09b4581ea32602`
(`feat: build Jarvis iPhone conversation UI`).

Static-review round-1 fix commit:
`a28e8d104a85c77e8434125de9611aa40ae50845`
(`fix: serialize Jarvis iOS operations`).

## Files

- `ios/project.yml`
- `ios/JarvisIOS/App/JarvisIOSApp.swift`
- `ios/JarvisIOS/App/AppModel.swift`
- `ios/JarvisIOS/Design/JarvisTheme.swift`
- `ios/JarvisIOS/Conversation/ConversationView.swift`
- `ios/JarvisIOS/Conversation/VoiceOrb.swift`
- `ios/JarvisIOS/Tasks/TaskListView.swift`
- `ios/JarvisIOS/Devices/DeviceView.swift`
- `ios/JarvisIOS/Confirmation/ActionPreviewSheet.swift`
- `ios/JarvisIOSTests/AppModelTests.swift`
- `ios/JarvisIOSUITests/ConversationUITests.swift`

No Task 6–8 voice, intent, widget, CI, cloud-build, or integration files were
created. The SDD progress ledger was not changed.

## Implementation decisions

- The root is a three-tab SwiftUI shell named `对话 / 任务 / 设备`. The
  conversation tab keeps the approved hierarchy: connection header, voice
  core, conversation, computer status, composer, then the tab bar.
- The dominant surface is system black. White text, subdued secondary text,
  and semantic green, amber, red, and cyan accents always accompany explicit
  text or symbols; color is never the only state indicator.
- `AppModel.Phase` contains all ten required cases: `idle`, `listening`,
  `transcribing`, `thinking`, `awaitingConfirmation(ActionPreview)`,
  `executing`, `completed`, `failed`, `offline`, and `resultUnknown`. Every
  case has a visible Chinese title and explanation.
- `BridgeClient` conforms to a narrow injected `JarvisBridgeClient` protocol.
  The production seam accepts Task 4 requests and responses, while
  `-ui-testing -fixture <name>` creates deterministic in-process state without
  touching URLSession, Keychain, or a LAN Bridge.
- `Phase.allowsTransition(to:)` is the single explicit transition policy after
  initialization. Each async Bridge submission owns a monotonically increasing
  operation generation; success, result-unknown, and error continuations check
  that ownership before changing phase, notice, or messages. Disconnecting
  invalidates the active generation so delayed replies cannot overwrite a new
  operation.
- Public `submit(text:)` sends a Task 4 `.chat` request through the injected
  Bridge, and the composer delegates to it. Public
  `submit(proposal:)` accepts a typed `RemoteToolProposal`, creates a Task 4
  `.tool` request, applies the Bridge's real `awaiting_confirmation` payload,
  and lets the existing preview issue exactly one `.confirm` request.
- Thinking, awaiting-confirmation, and executing states reject competing text
  and voice starts in the model. The corresponding UI controls are also
  disabled while those phases are active.
- A pending external message displays the recipient and complete message in an
  interactive-dismiss-disabled preview. Allow creates one Task 4 confirmation
  request. Cancel only dismisses locally, changes the visible notice to
  `已取消，未执行`, and never calls the client.
- Ambiguous results display `结果待确认` and the mandatory warning
  `不要重复发送，请检查目标应用`.
- The device view exposes only human-readable connection and certificate-pin
  verification state. Its model carries no secret, fingerprint, or pairing
  proof value.
- `VoiceOrb` has explicit accessibility labels and hints. Its pulsing animation
  is disabled when Reduce Motion is enabled.

## Test-first evidence and UI-test inventory

`ConversationUITests.swift` was created before the app target and production
views. The required RED command could not reach test discovery because the
Windows host could not start either Apple tool; executable RED/GREEN evidence
is therefore deferred rather than fabricated.

The five UI tests cover:

1. Connected conversation shell, accessible voice action, composer, computer
   status, and exactly three tabs.
2. Offline connection and phase text with the retained-draft explanation.
3. Confirmation recipient, full message, allow button, and cancel button.
4. Cancellation dismissal, `已取消，未执行`, and deterministic client call
   count remaining zero.
5. Result-unknown title and the no-duplicate-send warning.

For static-review round 1, `AppModelTests.swift` and its controllable injected
Bridge actor were written before the production changes. The attempted RED and
GREEN commands both stopped before compilation because this host cannot start
XcodeGen or Xcode. The six cloud-pending unit tests cover:

1. Public text submission emits a real Task 4 `.chat` request and only applies
   the Bridge response.
2. An older success arriving after a newer completion is ignored.
3. A stale timeout/error cannot replace a newer completion.
4. Text submission and voice start are rejected while confirmation executes.
5. A typed WeChat proposal emits `.tool`, applies an awaiting-confirmation
   preview, and emits `.confirm` with the original target request ID.
6. Cancelling a tool preview returns to idle without calling Bridge confirm.

## Local commands and results

All commands ran from
`C:\Users\Administrator\Documents\ChatGPT\工作项目\.worktrees\jarvis-ios`.

| Command | Result |
| --- | --- |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp='.task5-baseline-temp'` | Baseline: `184 passed in 12.71s`. |
| `py -3.12 -m ruff check src tests` | Baseline: `All checks passed!`. |
| `cd ios; xcodegen generate` before implementation | Exit 1: `xcodegen` is not recognized on this host. |
| Task 5 `xcodebuild test` command before implementation | Exit 1: `xcodebuild` is not recognized on this host. |
| Required-path, phase, localization, fixture, and UI-test inventory | Passed: 10 required paths, 10 phases, and 5 UI tests. |
| Python `yaml.safe_load` plus target/scheme assertions for `ios/project.yml` | Passed. This validates YAML structure, not the XcodeGen schema. |
| UI production-source scan for force casts/unwraps, fatal traps, UserDefaults, URLSession, Keychain, and logging | No findings. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp='.task5-final-temp'` | Final: `184 passed in 12.85s`. |
| `py -3.12 -m ruff check src tests` | Final: `All checks passed!`. |
| Exact staged-path comparison and `git diff --cached --check` | Passed; only the ten Task 5 deliverables were staged and no whitespace errors were reported. |
| `cd ios; xcodegen generate` after implementation | Exit 1: `xcodegen` is not recognized on this host. |
| Task 5 `xcodebuild test` command after implementation | Exit 1: `xcodebuild` is not recognized on this host. |
| `git show --check --oneline --stat 8bd7fc8f134c5035b60c2e561a09b4581ea32602` | Passed; the source commit renders with no whitespace errors. |
| Static-review round-1 YAML, exact-path, centralized-phase-mutation, generation-owner, request-kind, safety, and test-inventory checks | Passed: 4 changed source/config paths, 6 AppModel unit tests, and the original 5 UI tests. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp='.task5-review1-final-temp'` | Round 1: `184 passed in 12.81s`. |
| `py -3.12 -m ruff check src tests` | Round 1: `All checks passed!`. |
| `cd ios; xcodegen generate` after round-1 implementation | Exit 1: `xcodegen` is not recognized on this host. |
| Full Task 5 `xcodebuild test` after round-1 implementation | Exit 1: `xcodebuild` is not recognized on this host. |
| `git show --check --oneline --stat a28e8d104a85c77e8434125de9611aa40ae50845` | Passed; the review-fix commit renders with no whitespace errors. |
| Static-review round-2 XCTest-isolation source assertion | Passed: no class-level `@MainActor`, all 6 tests and the 2 AppModel-state helpers are locally `@MainActor`, and `ControllableBridgeClient` remains an unannotated actor. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp='.task5-review2-temp'` | Round 2: `184 passed in 12.98s`. |
| `py -3.12 -m ruff check src tests` | Round 2: `All checks passed!`. |
| Static-review round-3 XCTest-helper isolation source assertion | Passed: all 4 async helpers are locally `@MainActor`; the class and controllable Bridge actor remain nonisolated; 6 tests and XcodeGen targets are unchanged. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp='.task5-review3-temp'` | Round 3: `184 passed in 12.91s`. |
| `py -3.12 -m ruff check src tests` | Round 3: `All checks passed!`. |

The Python, YAML, source-inventory, and Git checks prove repository hygiene and
desktop non-regression only. They do not prove that the Swift source compiles or
that the iOS UI tests pass.

## Codemagic/macOS validation gate

Task 7 must run the exact Task 5 gate on a macOS runner with XcodeGen and the
requested iPhone simulator runtime:

```bash
cd ios && xcodegen generate
xcodebuild test \
  -project JarvisIOS.xcodeproj \
  -scheme JarvisIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

The gate closes only when XcodeGen accepts `project.yml`, both Swift package
products resolve, the app compiles under Swift 6, and all six AppModel unit
tests plus all five UI tests pass. Until that evidence is recorded, Task 5
remains cloud-validation-pending.
