# Task 2 Report

## Scope

Implemented Task 2 changes only in:

- `ios/Sources/JarvisCore/BridgeClient.swift`
- `ios/Sources/JarvisCore/KeychainDeviceStore.swift`
- `ios/Tests/JarvisCoreTests/BridgeClientTests.swift`

## What Changed

- Added endpoint-aware transport setup via `BridgeEndpoint` with Bonjour-discovered and manual endpoint support.
- Added explicit `BridgeConnectionState` tracking and exposed `connectionState()` for reconnect/disconnect visibility.
- Added `BridgeEvent` decoding for preview, progress, terminal, and rejection messages.
- Added pairing exchange support with `completePairing(...)` that validates freshness and challenge/response matching before persisting credentials.
- Updated request handling to decode task previews/terminal results into `BridgeResponse` and surface `TaskRejection` as `BridgeError.requestRejected(...)`.
- Restricted Keychain persistence to device identity and secret only; certificate pinning stays with the selected endpoint instead of persisted credentials.
- Reworked focused tests around pairing, rejection handling, duplicate request IDs, disconnect behavior, reconnect-safe reads, and endpoint pinning.

## Verification

### Commands run

1. `swift test --package-path ios --filter JarvisCoreTests/BridgeClientTests`
2. `git diff --check`

### Output

`swift test --package-path ios --filter JarvisCoreTests/BridgeClientTests`

```text
swift:
The term 'swift' is not recognized as a name of a cmdlet, function, script file, or executable program.
```

`git diff --check`

```text
No whitespace errors reported. Git printed existing LF/CRLF conversion warnings for the worktree.
```

## Notes

- Swift/Xcode tooling is unavailable in this Windows environment, so the new iOS tests were written and reviewed but not compiled or executed locally.
- The current implementation preserves existing request/confirm/cancel entry points while extending the client with endpoint/state/pairing helpers for later UI integration.

## Round 1 Fixes

### Review items addressed

- Confirm/cancel transport now serializes a `TaskConfirmation` payload with explicit `decision` and fresh `decided_at`, wrapped alongside the signed authorization request.
- Pair-claim persistence now requires the returned credential payload to echo the expected `device_id` and `device_public_key`; mismatches are rejected before any Keychain write.
- Read-only HTTP/protocol failures now transition out of `.connecting` into `.paired` instead of leaving the transport state ambiguous.

### Additional tests added or updated

- Confirmation/cancellation payload serialization now checks that the `confirmation` object includes `decision`, `task_id`, and `decided_at`.
- Pairing tests now cover returned `device_id` mismatch and returned `device_public_key` mismatch before persistence.
- Read-only status tests now cover HTTP failure and protocol-decoding failure state fallback to `.paired`.

### Additional verification on 2026-09-01

1. `swift test --package-path ios --filter JarvisCoreTests/BridgeClientTests`
2. `git diff --check`

### Additional output

`swift test --package-path ios --filter JarvisCoreTests/BridgeClientTests`

```text
swift:
The term 'swift' is not recognized as a name of a cmdlet, function, script file, or executable program.
```

`git diff --check`

```text
No whitespace errors reported. Git printed existing LF/CRLF conversion warnings for the worktree.
```
