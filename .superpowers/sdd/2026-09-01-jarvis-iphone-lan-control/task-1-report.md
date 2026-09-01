# Task 1 report — protocol and pairing models

## Scope

Implemented only the Task 1 protocol/signing slice in the shared iOS worktree:

- `ios/Sources/JarvisProtocol/BridgeModels.swift`
- `ios/Sources/JarvisProtocol/RequestSigner.swift`
- `ios/Tests/JarvisProtocolTests/BridgeModelsTests.swift`
- `ios/Tests/JarvisProtocolTests/RequestSignerTests.swift`

No other source files were modified for this task.

## Implementation

- Expanded `BridgeModels.swift` with versioned Codable message types for:
  - discovery
  - pairing challenge
  - pairing challenge response
  - task submission
  - task preview
  - task confirmation
  - task progress
  - task terminal result
  - task rejection with explicit rejection reason codes
- Added `SignedRequestEnvelope` so signed request transport has a stable protocol model instead of ad hoc JSON assembly only.
- Added protocol-level timestamp validation helpers for malformed and stale message detection.
- Added request-signing helpers in `RequestSigner.swift` for:
  - canonical signing payload generation
  - request metadata freshness validation
- Preserved the existing `BridgeRequest`, `BridgeResponse`, and HMAC signing entry points used by the current `BridgeClient`.

## Tests added

- Discovery message wire-field coverage
- Pairing challenge round-trip coverage
- Pairing challenge response unknown-field rejection
- Task submission request/idempotency coverage
- Task preview, confirmation, progress, terminal result round-trips
- Explicit rejection reason coverage
- Timestamp validation for malformed and stale messages
- Signed envelope wire-shape coverage
- Canonical signing payload coverage
- Request metadata freshness acceptance/rejection coverage

## Verification

Attempted focused Swift test command from `ios/`:

```powershell
swift test --filter JarvisProtocolTests
```

Result:

```text
The term 'swift' is not recognized as a name of a cmdlet, function, script file, or executable program.
```

Additional environment check:

```powershell
Get-Command swift,swiftc,xcrun -ErrorAction SilentlyContinue
```

Result: no Swift toolchain commands were available on this Windows host.

Repository patch hygiene check:

```powershell
git diff --check -- ios/Sources/JarvisProtocol/BridgeModels.swift ios/Sources/JarvisProtocol/RequestSigner.swift ios/Tests/JarvisProtocolTests/BridgeModelsTests.swift ios/Tests/JarvisProtocolTests/RequestSignerTests.swift
```

Result: no diff errors; Git reported only LF→CRLF working-copy warnings.

## Notes

- Because Swift is unavailable here, the new protocol surface is verified by source review and test authoring, not by executing the XCTest target.
- The current `BridgeClient` still uses its existing request/response path. The new Task 1 models are additive and intended to support later transport/UI tasks.

## Concerns

- Swift compile/test execution is still blocked on a macOS or Windows host with a Swift toolchain installed.
- `BridgeClient` currently hand-builds the signed envelope JSON; a later task may want to switch it to `SignedRequestEnvelope` for one canonical path.

## Fix round 1

### Review items addressed

- Added persistent device identity binding fields to the pairing protocol models:
  - `PairingPayload.deviceID`
  - `PairingPayload.devicePublicKey`
  - `PairingChallengeResponse.deviceID`
  - `PairingChallengeResponse.devicePublicKey`
- Added explicit freshness validation methods for:
  - `PairingChallenge`
  - `PairingChallengeResponse`
  - `TaskConfirmation`
- Tightened lifecycle validation so:
  - `TaskProgress` rejects terminal states
  - `TaskTerminalResult` rejects non-terminal states

### Tests added in fix round 1

- Pairing payload device identity/key binding coverage
- Pairing challenge response device identity/key binding coverage
- Stale pairing challenge rejection
- Stale pairing challenge response rejection
- Stale task confirmation rejection
- Terminal-state rejection for `TaskProgress`
- Non-terminal-state rejection for `TaskTerminalResult`

### Verification

Attempted focused Swift test command again:

```powershell
swift test --filter JarvisProtocolTests
```

Output:

```text
The term 'swift' is not recognized as a name of a cmdlet, function, script file, or executable program.
```

Toolchain availability check:

```powershell
Get-Command swift,swiftc,xcrun -ErrorAction SilentlyContinue | Select-Object Name,Source
```

Output: no results.

Patch hygiene check:

```powershell
git diff --check -- ios/Sources/JarvisProtocol/BridgeModels.swift ios/Sources/JarvisProtocol/RequestSigner.swift ios/Tests/JarvisProtocolTests/BridgeModelsTests.swift ios/Tests/JarvisProtocolTests/RequestSignerTests.swift
```

Output:

```text
warning: in the working copy of 'ios/Sources/JarvisProtocol/BridgeModels.swift', LF will be replaced by CRLF the next time Git touches it
warning: in the working copy of 'ios/Tests/JarvisProtocolTests/BridgeModelsTests.swift', LF will be replaced by CRLF the next time Git touches it
```

No diff-format errors were reported.

### Residual note

- To preserve source compatibility for existing non-Task-1 call sites, `PairingPayload` keeps a compatibility initializer that synthesizes placeholder identity/key values. The stricter wire-level initializer and decoding path require explicit identity binding, but downstream transport callers should migrate to the full initializer in a later task.
