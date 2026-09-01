# Jarvis iOS cloud build and TestFlight handoff

## Current status

The Codemagic configuration is committed but has **not** run in Codemagic yet.
There is no cloud build URL, artifact, simulator result, Swift pass result, or
TestFlight upload to report. The dynamic macOS gate for Tasks 4–6 remains open.
The same-Wi-Fi iPhone LAN-control gate from September 1, 2026 also remains
open until a real Codemagic run proves the new protocol, transport, AppModel,
and UI checks on macOS.

## Unsigned validation workflow

`ios_unsigned` is the normal Apple Silicon (`mac_mini_m2`) workflow. It has no
signing setup and must not publish an IPA. It performs the following commands:

```bash
brew install xcodegen
cd ios && xcodegen generate
bash scripts/ci/verify-ios-project.sh
cd ios && swift test --filter JarvisProtocolTests
cd ios && swift test --filter JarvisCoreTests
xcodebuild test \
  -project ios/JarvisIOS.xcodeproj \
  -scheme JarvisIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisIOSTests/AppModelTests \
  -only-testing:JarvisIOSUITests/ConversationUITests \
  CODE_SIGNING_ALLOWED=NO
```

The simulator command also writes these retained artifacts relative to the
repository root:

- `build/test-results/JarvisIOS.xcresult`
- `build/test-results/junit/**/*.xml`

The JUnit XML is generated with Codemagic's `xcode-project junit-test-results`
command after the result bundle is created. It runs even when `xcodebuild test`
fails, so a failed simulator run retains its diagnostics. A successful cloud
run requires the Swift package tests, XcodeGen preflight, and unsigned
simulator tests all to pass. In LAN-control terms, that means the
`JarvisProtocolTests` suite validates the signed wire protocol, the
`JarvisCoreTests` suite validates the pairing and transport client, and the
simulator run must execute `AppModelTests` plus `ConversationUITests`.

## LAN prerequisites and simulator limits

This phase is same Wi-Fi only. A real operator flow requires the iPhone and the
desktop bridge to be on the same LAN, the desktop bridge to advertise or expose
its reachable HTTPS endpoint, and the iPhone user to complete the one-time
pairing flow before any request can execute.

Codemagic cannot prove that live pairing path by itself because the unsigned
workflow runs on a hosted macOS simulator, not on the target LAN with the
Windows bridge. The simulator gate still proves the Swift protocol, transport
state handling, AppModel transitions, and confirmation UI rendering, but it
does not prove Bonjour discovery, manual-IP reachability to the desktop,
certificate trust against the live bridge, or end-to-end same-Wi-Fi pairing.

The local desktop bridge regression command for this feature slice is:

```powershell
$env:PYTHONPATH='src'; py -3.12 -m pytest tests/test_lan_bridge.py -q
```

Run that together with `py -3.12 -m ruff check src tests` before claiming the
desktop side of the LAN handoff is healthy.

## Required Codemagic evidence

Do not close the cloud gate with a static review alone. A real Codemagic run
must provide all of the following evidence:

1. The Codemagic build URL for the exact run.
2. Step logs showing `xcodegen generate`, `verify-ios-project.sh`,
   `swift test --filter JarvisProtocolTests`, and
   `swift test --filter JarvisCoreTests` all exited successfully.
3. The simulator `xcodebuild test` log showing
   `JarvisIOSTests/AppModelTests` and `JarvisIOSUITests/ConversationUITests`
   were selected and passed on the named simulator image.
4. The retained XCResult bundle at `build/test-results/JarvisIOS.xcresult` and
   the retained JUnit XML at `build/test-results/junit/**/*.xml`, or an
   explicit failing-run explanation if artifact generation itself broke.
5. If a signed run is later performed, the manual `submit_to_testflight: true`
   input, the `xcode-project use-profiles` assignment output, the produced IPA
   artifact name, and the App Store Connect/TestFlight result.

To run it after connecting this repository in Codemagic, select **iOS unsigned
tests**. The workflow triggers for pushes and pull requests; verify that the
selected Xcode image includes an iOS Simulator named `iPhone 16` before relying
on a new image version.

## Preflight contract

Run the preflight only after generating the Xcode project:

```bash
cd ios && xcodegen generate
cd .. && bash scripts/ci/verify-ios-project.sh
```

It reports every missing required source input it can find: the XcodeGen
manifest, the four app/test targets, the `JarvisIOS` scheme, four bundle IDs,
and the two scheme test targets. It then requires the generated
`JarvisIOS.xcodeproj` and shared `JarvisIOS.xcscheme`. The script parses only
the scheme's `TestAction/Testables` and requires exactly one
`BlueprintName` for each of `JarvisIOSTests` and `JarvisIOSUITests`, with no
unrelated testable. It also verifies the generated target/scheme listing and
runs `xcodebuild -showBuildSettings -target` separately for all four targets,
requiring each target's exact `PRODUCT_BUNDLE_IDENTIFIER`. A bundle ID merely
appearing elsewhere in the project does not satisfy the preflight.

For a local missing-manifest RED check without modifying tracked files:

```bash
PROJECT_YML=/tmp/jarvis-missing/project.yml bash scripts/ci/verify-ios-project.sh
```

This must exit nonzero and name the missing manifest. The script also accepts
`XCODE_PROJECT`, `XCODE_SCHEME`, and `XCODEBUILD_BIN` overrides so its generated
scheme and build-setting contracts can be exercised with isolated test fixtures
on Windows. A normal post-generation run without Xcode still exits nonzero with
an actionable `xcodebuild ... is unavailable` error; a test double is only for
local contract tests and does not substitute for the Codemagic macOS gate.

## TestFlight is manual and opt-in

`ios_testflight` has no push/PR trigger and defaults
`submit_to_testflight` to `false`. Codemagic skips the workflow unless a human
starts it with the explicit Boolean input `submit_to_testflight: true`.
Only that opt-in path enables managed App Store signing, produces an IPA, and
publishes through the App Store Connect integration named
`jarvis_app_store_connect`. TestFlight remains manual-only for the LAN-control
handoff as well; nothing in the unsigned workflow enables publishing.

Before the first signed run, an account owner must:

1. Join the Apple Developer Program and register the App Group
   `group.com.jarvisassistant.shared`.
2. Create an explicit main-app App ID for `com.jarvisassistant.ios`, enable its
   App Groups capability, and attach `group.com.jarvisassistant.shared`.
3. Create a separate explicit Widget extension App ID for
   `com.jarvisassistant.ios.widget`, enable its App Groups capability, and
   attach the same `group.com.jarvisassistant.shared`. Both checked-in
   entitlements files request this group, so enabling it for only one App ID
   is insufficient.
4. Create the Jarvis main-app record in App Store Connect for
   `com.jarvisassistant.ios`, including its unique Apple ID and marketing
   version metadata. The Widget is embedded in that app; it is not a separate
   App Store Connect app record.
5. Create or select an Apple Distribution certificate available to Codemagic.
   Create two distinct App Store distribution provisioning profiles: one for
   the main App ID `com.jarvisassistant.ios`, and one for the Widget App ID
   `com.jarvisassistant.ios.widget`. Both profiles must contain the shared App
   Group entitlement and may use the same distribution certificate.
6. Create a dedicated App Store Connect API key with App Manager permission.
   Add its issuer ID, key ID, and `.p8` private key to Codemagic's encrypted
   App Store Connect integration, giving that integration the exact reference
   name `jarvis_app_store_connect` (or update the YAML reference to the chosen
   integration name).
7. Configure Codemagic managed signing so the
   `com.jarvisassistant.ios*` bundle filter retrieves both exact distribution
   profiles. On the signed run, inspect the `xcode-project use-profiles` output
   and confirm that it assigns the main-app profile to `JarvisIOS` and the
   Widget profile to `JarvisWidget`. Certificates, provisioning profiles,
   passwords, and the API private key stay in Codemagic; do not add them to
   this repository or committed CI variables.
8. Create the internal TestFlight tester group named `Jarvis Internal` (or
   change `beta_groups` in `codemagic.yaml` to the approved group name), then
   manually start **iOS TestFlight internal (manual opt-in)** with
   `submit_to_testflight` set to `true`.
9. Confirm the completed upload in App Store Connect and add the uploaded build
   to the internal group. Record the actual Codemagic build URL and artifact
   names in the release handoff only after that run completes.

## Signed-build version contract

The generated app and Widget Info.plists both resolve
`CFBundleShortVersionString` from `MARKETING_VERSION` and `CFBundleVersion`
from `CURRENT_PROJECT_VERSION`. The signed workflow provides the approved
`MARKETING_VERSION` and uses Codemagic's positive, monotonically increasing
`BUILD_NUMBER` as the sole `CURRENT_PROJECT_VERSION` for that run.

After XcodeGen and before profile assignment/archive,
`scripts/ci/set-ios-version.sh` runs `agvtool new-marketing-version` and
`agvtool new-version -all`, then reads Release build settings for both
`JarvisIOS` and `JarvisWidget`. It fails the signed build if either target does
not have the exact same marketing version and Codemagic build number. Before
uploading another build for the same App Store version, confirm Codemagic's
next `BUILD_NUMBER` is greater than the last uploaded `CFBundleVersion`; never
replace it with a reused or hard-coded number.

The repository intentionally contains no `.p8` files, certificates,
provisioning profiles, passwords, or other signing secrets.
