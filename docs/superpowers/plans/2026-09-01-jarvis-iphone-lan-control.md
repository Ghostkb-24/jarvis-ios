# Jarvis iPhone LAN Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the same-Wi‑Fi iPhone-to-desktop Jarvis control loop with pairing, signed requests, task state updates, and confirmation-safe cross-app actions.

**Architecture:** Extend the existing Swift `BridgeClient`/`AppModel` boundaries and add a versioned LAN bridge adapter on the desktop. Bonjour/manual-IP discovery feeds a one-time pairing flow; Keychain stores the resulting device key and each request carries an idempotency key and signature. Existing desktop risk policies remain authoritative.

**Tech Stack:** Swift 6, SwiftUI, URLSession/WebSocket or Network framework, Bonjour, Keychain; Python desktop bridge and existing orchestrator; XCTest, Swift Testing, and Codemagic unsigned simulator workflow.

**Spec:** `docs/superpowers/specs/2026-09-01-jarvis-iphone-lan-control-design.md`

## Global Constraints

- Same Wi‑Fi only; no external relay in this phase.
- Cross-application actions require explicit confirmation on iPhone.
- Payment, file deletion, and password entry remain blocked.
- No background always-on recording.
- No signing credentials, certificates, profiles, or API keys in the repository.

### Task 1: Define mobile LAN protocol and pairing models

**Files:**
- Modify: `ios/Sources/JarvisProtocol/BridgeModels.swift`
- Modify: `ios/Sources/JarvisProtocol/RequestSigner.swift`
- Test: `ios/Tests/JarvisProtocolTests/BridgeModelsTests.swift`
- Test: `ios/Tests/JarvisProtocolTests/RequestSignerTests.swift`

- [ ] Add versioned Codable messages for discovery, pairing challenge/response, task submission, preview, confirmation, progress, terminal result, and explicit rejection reasons.
- [ ] Add request ID/idempotency key and canonical signing payload; reject malformed or stale messages in tests.
- [ ] Run `cd ios && swift test --filter JarvisProtocolTests` and commit the protocol slice.

### Task 2: Implement LAN pairing and transport in BridgeClient

**Files:**
- Modify: `ios/Sources/JarvisCore/BridgeClient.swift`
- Modify: `ios/Sources/JarvisCore/KeychainDeviceStore.swift`
- Test: `ios/Tests/JarvisCoreTests/BridgeClientTests.swift`

- [ ] Add Bonjour/manual endpoint selection and a one-time pairing code exchange.
- [ ] Persist only the paired device identity/key in Keychain; expose connection states and recoverable errors.
- [ ] Implement signed request submission, confirmation, event decoding, and safe query-only reconnect behavior.
- [ ] Add tests for pairing, signature failure, duplicate request IDs, disconnect, and no retry of side-effecting requests.
- [ ] Run the focused Swift tests and commit the transport slice.

### Task 3: Connect AppModel and SwiftUI views

**Files:**
- Modify: `ios/JarvisIOS/App/AppModel.swift`
- Modify: `ios/JarvisIOS/Devices/DeviceView.swift`
- Modify: `ios/JarvisIOS/Conversation/ConversationView.swift`
- Modify: `ios/JarvisIOS/Confirmation/ActionPreviewSheet.swift`
- Test: `ios/JarvisIOSTests/AppModelTests.swift`
- Test: `ios/JarvisIOSUITests/ConversationUITests.swift`

- [ ] Bind connection/pairing state and task lifecycle to the existing views without changing the A-style visual language.
- [ ] Route voice transcript and text input into signed submissions; render preview cards before cross-app confirmation.
- [ ] Ensure blocked risk categories show refusal copy and no confirm control.
- [ ] Add unit/UI coverage for unpaired, connected, awaiting confirmation, cancelled, failed, and succeeded flows.
- [ ] Run Swift package tests and available iOS tests; commit the UI integration.

### Task 4: Add desktop LAN bridge adapter and integration tests

**Files:**
- Create: `src/jarvis_assistant/lan_bridge.py`
- Modify: `src/jarvis_assistant/app.py`
- Test: `tests/test_lan_bridge.py`

- [ ] Expose a local-only HTTP/WebSocket endpoint with pairing challenge, signed request verification, idempotency, and task-event streaming.
- [ ] Map requests into existing orchestrator proposals and preserve the existing confirmation policy for cross-app actions and blocked risks.
- [ ] Add integration tests for pairing, invalid signatures, duplicate submissions, confirmation, rejection, and disconnect cleanup.
- [ ] Run `$env:PYTHONPATH='src'; py -3.12 -m pytest tests/test_lan_bridge.py -q` and Ruff; commit the adapter.

### Task 5: CI validation and cloud handoff

**Files:**
- Modify: `codemagic.yaml`
- Modify: `docs/ios-cloud-build.md`
- Modify: `docs/superpowers/sdd/2026-08-28-jarvis-ios/task-7-report.md`

- [ ] Add protocol/transport/UI tests to the unsigned workflow without enabling TestFlight publishing.
- [ ] Document LAN test prerequisites and simulator limitations; keep cloud status evidence-based.
- [ ] Run all local Python tests/Ruff and static CI contract tests; record unavailable macOS commands honestly.
- [ ] Commit CI/documentation updates and leave the Codemagic dynamic gate open until a real run.
