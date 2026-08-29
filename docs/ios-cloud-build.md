# Jarvis iOS cloud build and TestFlight handoff

## Current status

The Codemagic configuration is committed but has **not** run in Codemagic yet.
There is no cloud build URL, artifact, simulator result, Swift pass result, or
TestFlight upload to report. The dynamic macOS gate for Tasks 4–6 remains open.

## Unsigned validation workflow

`ios_unsigned` is the normal Apple Silicon (`mac_mini_m2`) workflow. It has no
signing setup and must not publish an IPA. It performs the following commands:

```bash
brew install xcodegen
cd ios && xcodegen generate
bash scripts/ci/verify-ios-project.sh
cd ios && swift test
xcodebuild test \
  -project ios/JarvisIOS.xcodeproj \
  -scheme JarvisIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
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
simulator tests all to pass.

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
`JarvisIOS.xcodeproj`, verifies its target/scheme listing through `xcodebuild`,
and checks that all four bundle IDs reached the generated project.

For a local missing-manifest RED check without modifying tracked files:

```bash
PROJECT_YML=/tmp/jarvis-missing/project.yml bash scripts/ci/verify-ios-project.sh
```

This must exit nonzero and name the missing manifest. On a Windows host without
Xcode, source-level and shell syntax checks are useful, but the post-generation
preflight cannot pass and does not substitute for the Codemagic macOS gate.

## TestFlight is manual and opt-in

`ios_testflight` has no push/PR trigger and defaults
`submit_to_testflight` to `false`. Codemagic skips the workflow unless a human
starts it with the explicit Boolean input `submit_to_testflight: true`.
Only that opt-in path enables managed App Store signing, produces an IPA, and
publishes through the App Store Connect integration named
`jarvis_app_store_connect`.

Before the first signed run, an account owner must:

1. Join the Apple Developer Program and create the App ID
   `com.jarvisassistant.ios` with its required capabilities.
2. Create the Jarvis app record in App Store Connect, including a unique Apple
   app ID and version metadata.
3. Create a dedicated App Store Connect API key with App Manager permission.
   Add its issuer ID, key ID, and `.p8` private key to Codemagic's encrypted
   App Store Connect integration, giving that integration the exact reference
   name `jarvis_app_store_connect` (or update the YAML reference to the chosen
   integration name).
4. Configure Codemagic's managed App Store distribution signing for
   `com.jarvisassistant.ios`. Certificates, provisioning profiles, passwords,
   and the API private key stay in Codemagic; do not add them to this repository
   or CI variables committed to Git.
5. Create the internal TestFlight tester group named `Jarvis Internal` (or
   change `beta_groups` in `codemagic.yaml` to the approved group name), then
   manually start **iOS TestFlight internal (manual opt-in)** with
   `submit_to_testflight` set to `true`.
6. Confirm the completed upload in App Store Connect and add the uploaded build
   to the internal group. Record the actual Codemagic build URL and artifact
   names in the release handoff only after that run completes.

The repository intentionally contains no `.p8` files, certificates,
provisioning profiles, passwords, or other signing secrets.
