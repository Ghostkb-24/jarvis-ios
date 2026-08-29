# Task 6 Report — Voice, Siri/App Shortcuts, and Widgets

## Status

Task 6 is **implementation-ready / cloud-validation-pending**. The voice
session, permission and lifecycle safety gates, Siri/App Shortcuts entry,
home/lock-screen widget, iOS 18 Control Widget, App Group status snapshot, and
their test sources are implemented. This Windows host has no Swift, XcodeGen,
or Xcode toolchain, so no Swift compilation, package-test pass, simulator-test
pass, or XcodeGen schema acceptance is claimed.

Implementation commit:
`a2a20f92923532ad90c1d34a11136ce76928c896`
(`feat: add Jarvis voice and iOS entry points`).

The SDD progress ledger was not changed. No Task 7 Codemagic configuration or
Task 8 integration/acceptance work was created.

## Files

- `ios/JarvisIOS/Voice/SpeechSession.swift`
- `ios/JarvisIOS/Voice/SpeechPermissionView.swift`
- `ios/JarvisIntents/StartJarvisIntent.swift`
- `ios/JarvisIntents/JarvisShortcuts.swift`
- `ios/JarvisWidget/JarvisWidget.swift`
- `ios/JarvisWidget/JarvisControl.swift`
- `ios/Tests/JarvisCoreTests/SpeechSessionTests.swift`
- `ios/JarvisIOSTests/VoiceEntryTests.swift`
- `ios/JarvisIOS/JarvisIOS.entitlements`
- `ios/JarvisWidget/JarvisWidget.entitlements`
- Modified `ios/JarvisIOS/App/AppModel.swift`
- Modified `ios/JarvisIOS/App/JarvisIOSApp.swift`
- Modified `ios/JarvisIOS/Conversation/ConversationView.swift`
- Modified `ios/Package.swift`
- Modified `ios/project.yml`

## Voice and lifecycle decisions

- `SpeechSession` uses injected `SpeechPermissionAuthorizing`,
  `SpeechRecognizing`, and `SpeechAudioCapturing` seams. Production adapters
  use `AVCaptureDevice`/`SFSpeechRecognizer` permission APIs,
  `AVAudioEngine`, and `SFSpeechAudioBufferRecognitionRequest`.
- Construction has no permission or audio side effect. `start() async throws`
  checks current permission and requests microphone/speech access only after
  the user explicitly presses the voice control. Denied/restricted permission
  does not prepare recognition or start audio, and the UI provides a visible
  explanation plus a Settings action without repeatedly prompting.
- The plan/brief simultaneously required the exact compatibility surface
  `stop() async throws -> String` and a structured low-confidence return with
  `requiresReview`/`executableText`. The implementation preserves the exact
  string API for display-only callers and adds
  `stopResult() async throws -> SpeechTranscriptResult` as the execution safety
  surface. Its documentation explicitly says only `executableText` may be
  submitted.
- Confidence is normalized to `0...1`. Text below the default `0.70` threshold
  becomes `.reviewRequired`, retains visible text, and sets
  `executableText == nil`. Empty transcripts fail visibly.
- `AppModel` calls `submit(text:)` only after unwrapping non-nil
  `executableText`. Review-required text is placed in the composer with
  `识别结果需要确认，编辑后再发送`; it never calls the Bridge automatically.
- `SpeechSession` and `AppModel` both expose visible
  listening/transcribing/review/error state. Competing text and tool requests
  are also blocked while a permission decision is pending.
- Resign-active stops `AVAudioEngine`, removes its tap, deactivates the audio
  session, cancels recognition, and invalidates the AppModel voice generation.
  Entering background also cancels an outstanding permission/start task so a
  grant cannot cause recording to begin while the app is hidden. A system
  permission sheet's transient inactive phase does not itself start audio.

## Siri, Action button, and deep-link decisions

- `StartJarvisIntent` conforms to `OpenIntent` with a static AppEnum target and
  is included in both the app and Widget extension targets, matching Apple's
  Control Widget target-membership requirement. It records a one-shot,
  non-sensitive listening-entry flag in the App Group and opens the app to the
  conversation tab. It does not request permissions or start recording.
- `JarvisShortcuts` exposes the rendered phrases `启动 Jarvis` and
  `开始与 Jarvis 对话`. The same shortcut can be assigned to the iPhone Action
  button.
- The app registers and validates only `jarvis://listen`. Invalid scheme/host
  combinations are ignored. Home and lock-screen Widget families use that URL
  as their `widgetURL`.
- Apple's `OpenURLIntent` and URL-representation APIs require universal links
  and explicitly reject custom URL schemes. Therefore the iOS 18 Control
  Widget uses Apple's documented `OpenIntent + AppEnum` launch path and the
  same `.listening` destination rather than passing `jarvis://listen` to an
  unsupported `OpenURLIntent`. See
  [OpenURLIntent](https://developer.apple.com/documentation/appintents/openurlintent)
  and
  [Creating controls to perform actions across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system).

## Widget privacy and project configuration

- The App Group snapshot schema has exactly three fields:
  `connectionStatus`, `modelStatus`, and `updatedAt`. It contains no device ID,
  device secret, certificate fingerprint, pairing proof, signature, request
  text, or conversation text.
- AppModel writes the status-only snapshot and asks WidgetKit to reload the
  status widget. Missing or malformed snapshots render the offline fixture.
- The Siri/Control navigation flag is a one-shot Boolean stored separately
  from the status snapshot. It authorizes navigation only and is consumed on
  foreground entry; it does not authorize recording or execution.
- App and Widget entitlements contain only
  `group.com.jarvisassistant.shared`. No credential, certificate, profile,
  private key, or signing secret was added.
- XcodeGen now defines the Widget extension, embeds it in the app, gives the
  intent source target membership in both app and Widget, registers the custom
  URL scheme, and supplies microphone/speech privacy descriptions.
- `Package.swift` exposes a `JarvisVoice` library from the production
  `SpeechSession.swift` file so `swift test` exercises the same implementation
  as the app rather than a duplicate test copy.

## TDD evidence and test inventory

`SpeechSessionTests.swift` and `VoiceEntryTests.swift` were added while
`ios/JarvisIOS/Voice/SpeechSession.swift` was absent. The source inventory
recorded `False` for the production path before implementation. The attempted
RED command then stopped before test discovery because `swift` is not
installed on this Windows host. Executable RED/GREEN and compilation evidence
is deferred rather than fabricated.

There are 8 package speech tests:

1. Initialization does not request permission or start audio.
2. Explicit start requests undetermined permission and enters listening.
3. Denied permission starts neither recognizer nor audio and exposes failure.
4. Low confidence requires review and has no executable text.
5. High confidence trims visible text and exposes executable text.
6. The exact string compatibility API returns visible text without granting
   low-confidence execution.
7. Resign-active stops audio, cancels recognition, and marks interruption.
8. Recognition failure still releases audio and exposes a visible failure.

There are 3 app-target voice-entry tests:

1. Low-confidence speech becomes a composer draft and never calls Bridge.
2. `jarvis://listen` prepares the conversation tab without requesting
   permission or starting audio.
3. Resign-active stops listening and submits no transcript.

## Local commands and results

All commands ran from
`C:\Users\Administrator\Documents\ChatGPT\工作项目\.worktrees\jarvis-ios`.

| Command | Result |
| --- | --- |
| `cd ios; swift test` before implementation | Exit 1 before test discovery: `swift` is not recognized. No executable RED result is claimed. |
| Task 6 required-path/source/config/entitlement static gate | Passed: 10 required Task 6 paths, exact app/Widget App Group entitlement, URL scheme, privacy descriptions, Widget extension and intent target membership. |
| Task 6 Swift structural/test/privacy static gate | Passed: balanced delimiters in 8 new Swift sources/tests, 8 speech tests, 3 app-entry tests, exact public APIs, two Shortcut phrases, and status-only Widget snapshot. |
| `$env:PYTHONPATH='src'; py -3.12 -m pytest -q --basetemp='C:\Users\Administrator\AppData\Local\Temp\jarvis-task6-final'` | `184 passed in 13.02s`. |
| `py -3.12 -m ruff check src tests` | `All checks passed!`. |
| Production Task 6 scan for `fatalError`, `try!`, force casts, logging, and Widget secret/fingerprint/proof/signature fields | No findings. |
| `git diff --check` and `git diff --cached --check` before source commit | Passed; only line-ending conversion notices were printed. |
| `git show --check --oneline --stat a2a20f9` | Passed with no whitespace errors. |
| `cd ios; swift test` after implementation | Exit 1: `swift` is not recognized. No Swift test pass is claimed. |
| `cd ios; xcodegen generate` | Exit 1: `xcodegen` is not recognized. XcodeGen schema acceptance is not claimed. |
| Task 5 simulator `xcodebuild test` command | Exit 1: `xcodebuild` is not recognized. No simulator pass is claimed. |

The Python, YAML/XML, source-inventory, privacy, and Git checks prove desktop
non-regression and repository hygiene only. They do not prove that Swift
compiles or that any iOS test passes.

## Codemagic/macOS completion gate

Task 7 must run both exact gates on a macOS runner with Swift 6, XcodeGen, an
iOS 18-capable SDK for Control Widget compilation, and the requested simulator:

```bash
cd ios && swift test
```

```bash
cd ios && xcodegen generate
xcodebuild test \
  -project JarvisIOS.xcodeproj \
  -scheme JarvisIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

The gate closes only when XcodeGen accepts the app/Widget/entitlement graph,
the JarvisVoice package and app copy compile under Swift 6, the iOS 18 Control
Widget availability boundary compiles with the selected SDK, all existing
Task 4/5 tests pass, all 8 speech tests pass, and all 3 voice-entry tests pass.
Until that evidence is recorded, Task 6 remains cloud-validation-pending.
