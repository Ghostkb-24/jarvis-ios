# Jarvis iPhone 第一版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建可独立对话、在同一 Wi‑Fi 安全连接 Windows Jarvis、并通过 Codemagic 构建的原生 iPhone Jarvis 第一版。

**Architecture:** 先在现有 Python 项目中实现版本化协议和局域网 JarvisBridge，再以 Swift Package + XcodeGen 工程实现 SwiftUI 客户端、App Intents 和 Widget。iPhone 与电脑通过一次性二维码配对、设备密钥签名和幂等请求通信；跨应用操作必须经过确认。

**Tech Stack:** Python 3.12、Pydantic 2、FastAPI、Uvicorn、Cryptography、Pytest；Swift 6、SwiftUI、CryptoKit、Speech、AppIntents、WidgetKit、XCTest；XcodeGen、Codemagic。

**Spec:** `docs/superpowers/specs/2026-08-28-jarvis-ios-design.md`

## Global Constraints

- 第一版只允许同一 Wi‑Fi，不配置公网端口或端口映射。
- 付款、删除文件、输入或读取密码永远不注册为工具。
- 跨应用和对外操作必须先展示目标及完整内容，并由用户确认。
- 敏感请求超时、断线或结果未知时不得自动重试。
- 配对密钥只存 iPhone Keychain 和 Windows Credential Manager，不写入源码、日志或 CI 配置。
- 云端回退必须逐次询问，不得自动上传请求。
- iPhone UI 固定采用 A「对话优先」布局和 2「极夜黑」风格。

---

### Task 1: 共享协议与签名验证

**Files:**
- Create: `src/jarvis_assistant/bridge/__init__.py`
- Create: `src/jarvis_assistant/bridge/protocol.py`
- Create: `src/jarvis_assistant/bridge/auth.py`
- Create: `tests/bridge/test_protocol.py`
- Create: `tests/bridge/test_auth.py`
- Modify: `pyproject.toml`

**Interfaces:**
- Produces: `BridgeRequest`, `BridgeResponse`, `TaskState`, `Risk`, `sign_request(secret: bytes, request: BridgeRequest) -> str`, `verify_request(secret: bytes, request: BridgeRequest, signature: str, now: datetime) -> None`.
- Consumes: Pydantic `BaseModel`; Python `hmac`, `hashlib`, `datetime`.

- [ ] **Step 1: Write failing protocol tests**

```python
def test_bridge_request_has_stable_canonical_payload() -> None:
    request = BridgeRequest(
        version=1,
        request_id="req-1",
        device_id="iphone-1",
        issued_at="2026-08-28T00:00:00Z",
        idempotency_key="idem-1",
        kind="tool",
        payload={"tool": "open_application", "arguments": {"name": "微信"}},
    )
    assert request.canonical_bytes() == (
        b'{"device_id":"iphone-1","idempotency_key":"idem-1",'
        b'"issued_at":"2026-08-28T00:00:00Z","kind":"tool",'
        b'"payload":{"arguments":{"name":"\\u5fae\\u4fe1"},'
        b'"tool":"open_application"},"request_id":"req-1","version":1}'
    )
```

- [ ] **Step 2: Run the protocol test and verify RED**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/bridge/test_protocol.py -q`

Expected: FAIL because `jarvis_assistant.bridge.protocol` does not exist.

- [ ] **Step 3: Implement the minimal versioned models**

```python
class BridgeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    version: Literal[1]
    request_id: str = Field(min_length=1)
    device_id: str = Field(min_length=1)
    issued_at: str
    idempotency_key: str = Field(min_length=1)
    kind: Literal["chat", "tool", "confirm", "cancel"]
    payload: dict[str, Any]

    def canonical_bytes(self) -> bytes:
        return json.dumps(
            self.model_dump(), ensure_ascii=True, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
```

- [ ] **Step 4: Write failing signature, expiry and tamper tests**

```python
def test_signature_rejects_tampered_and_expired_requests() -> None:
    signature = sign_request(b"secret", REQUEST)
    verify_request(b"secret", REQUEST, signature, NOW)
    with pytest.raises(AuthenticationError, match="signature"):
        verify_request(b"secret", TAMPERED_REQUEST, signature, NOW)
    with pytest.raises(AuthenticationError, match="expired"):
        verify_request(b"secret", REQUEST, signature, NOW + timedelta(minutes=6))
```

- [ ] **Step 5: Implement HMAC-SHA256 verification with a five-minute window**

Use `hmac.compare_digest`, parse UTC timestamps, and reject requests more than 300 seconds old or more than 30 seconds in the future.

- [ ] **Step 6: Run focused and full Python tests**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/bridge -q`

Expected: all bridge tests PASS.

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest -q`

Expected: existing desktop tests remain PASS.

- [ ] **Step 7: Commit**

```powershell
git add pyproject.toml src/jarvis_assistant/bridge tests/bridge
git commit -m "feat: define secure Jarvis bridge protocol"
```

---

### Task 2: 一次性二维码配对与设备撤销

**Files:**
- Create: `src/jarvis_assistant/bridge/pairing.py`
- Create: `src/jarvis_assistant/bridge/device_store.py`
- Create: `src/jarvis_assistant/bridge/tls.py`
- Create: `tests/bridge/test_pairing.py`
- Create: `tests/bridge/test_device_store.py`
- Create: `tests/bridge/test_tls.py`
- Modify: `src/jarvis_assistant/storage.py`

**Interfaces:**
- Consumes: `BridgeRequest` from Task 1.
- Produces: `PairingSession.create(ttl_seconds: int = 120)`, `PairingSession.claim(device_name: str, proof: str) -> PairedDevice`, `CredentialBackend`, `DeviceStore.get_secret(device_id: str) -> bytes | None`, `DeviceStore.revoke(device_id: str) -> None`, `BridgeTLSIdentity.load_or_create() -> BridgeTLSIdentity` and `certificate_sha256: str`.

- [ ] **Step 1: Write failing one-time and expiry tests**

```python
def test_pairing_code_can_only_be_claimed_once() -> None:
    session = PairingSession.create(now=NOW)
    device = session.claim("我的 iPhone", session.proof, now=NOW)
    assert device.name == "我的 iPhone"
    with pytest.raises(PairingError, match="already claimed"):
        session.claim("另一台 iPhone", session.proof, now=NOW)
```

- [ ] **Step 2: Verify RED**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/bridge/test_pairing.py -q`

Expected: FAIL because pairing types do not exist.

- [ ] **Step 3: Implement pairing payload without long-lived plaintext secrets**

The QR payload must contain `version`, `bridge_id`, local HTTPS URL, the SHA-256 fingerprint of the Bridge TLS certificate, one-time session ID, expiry and proof. Generate the long-lived device secret only after a successful claim and return it once over the pinned TLS connection.

- [ ] **Step 4: Write failing persistence and revocation tests**

```python
def test_revoked_device_secret_is_no_longer_available(tmp_path) -> None:
    store = DeviceStore(SQLiteStore.open(tmp_path / "state.db"), backend=MemoryCredentialBackend())
    store.save(DEVICE, b"secret")
    assert store.get_secret(DEVICE.id) == b"secret"
    store.revoke(DEVICE.id)
    assert store.get_secret(DEVICE.id) is None
```

- [ ] **Step 5: Write failing persistent TLS identity test**

```python
def test_tls_identity_is_stable_and_fingerprint_matches_certificate(tmp_path) -> None:
    first = BridgeTLSIdentity.load_or_create(tmp_path, backend=MemoryCredentialBackend())
    second = BridgeTLSIdentity.load_or_create(tmp_path, backend=MemoryCredentialBackend.shared())
    assert second.certificate_der == first.certificate_der
    assert second.certificate_sha256 == hashlib.sha256(first.certificate_der).hexdigest()
```

- [ ] **Step 6: Implement metadata, credentials and TLS identity**

Define `CredentialBackend` with `get_password(service: str, username: str) -> str | None`, `set_password(...) -> None` and `delete_password(...) -> None`. Add a `paired_devices` table containing device ID, display name, created time, last-seen time and revoked flag. Store device secrets through the backend key `jarvis-bridge-device:<device_id>`. Generate one self-signed Bridge certificate and private key, keep the private key in Windows Credential Manager, persist the public certificate, and pin its SHA-256 fingerprint during pairing.

- [ ] **Step 7: Run focused/full tests and commit**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/bridge -q`

Expected: PASS.

```powershell
git add src/jarvis_assistant/bridge src/jarvis_assistant/storage.py tests/bridge
git commit -m "feat: add one-time iPhone pairing"
```

---

### Task 3: 局域网 Bridge API、幂等与风险确认

**Files:**
- Create: `src/jarvis_assistant/bridge/server.py`
- Create: `src/jarvis_assistant/bridge/service.py`
- Create: `src/jarvis_assistant/bridge/idempotency.py`
- Create: `tests/bridge/test_server.py`
- Create: `tests/bridge/test_service.py`
- Modify: `src/jarvis_assistant/app.py`
- Modify: `pyproject.toml`

**Interfaces:**
- Consumes: Task 1 authentication, Task 2 `DeviceStore`, existing `Orchestrator` and `ToolRegistry`.
- Produces: `create_bridge_app(service: BridgeService) -> FastAPI`, endpoints `POST /v1/pair/claim`, `POST /v1/requests`, `GET /v1/tasks/{request_id}` and `POST /v1/tasks/{request_id}/confirm`.

- [ ] **Step 1: Write failing unauthorized, duplicate and confirmation tests**

```python
def test_sensitive_tool_waits_for_confirmation_and_duplicate_does_not_execute(client) -> None:
    first = client.post("/v1/requests", json=SIGNED_WECHAT_REQUEST)
    second = client.post("/v1/requests", json=SIGNED_WECHAT_REQUEST)
    assert first.status_code == 202
    assert first.json()["state"] == "awaiting_confirmation"
    assert second.json() == first.json()
    assert SENT_MESSAGES == []
```

- [ ] **Step 2: Verify RED**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/bridge/test_server.py -q`

Expected: FAIL because server module does not exist.

- [ ] **Step 3: Implement authenticated API and idempotency ledger**

Persist request ID, idempotency key, state and result summary. A duplicate must return the stored state and must never call the tool handler again.

- [ ] **Step 4: Implement explicit allowlist mapping**

Only expose `open_application`, `set_volume`, `search_files`, `open_file` and `send_wechat_message`. Reject `clipboard`, unknown tools, forbidden tools and malformed arguments at the Bridge boundary.

- [ ] **Step 5: Bind to LAN only and add lifecycle integration**

Start Uvicorn on the selected private IPv4 address, never `0.0.0.0` by default. Add tray actions “显示 iPhone 配对码” and “停止手机连接”. Shutdown must stop the server before closing SQLite.

- [ ] **Step 6: Run security-focused tests**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/bridge -q`

Expected: tests cover invalid signatures, expired requests, revoked devices, duplicate requests, unknown tools, confirmation and cancellation.

- [ ] **Step 7: Run full checks and commit**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest -q`

Run: `G:\python.exe -m ruff check src tests`

```powershell
git add pyproject.toml src/jarvis_assistant/app.py src/jarvis_assistant/bridge tests/bridge
git commit -m "feat: serve authenticated Jarvis LAN bridge"
```

---

### Task 4: Swift 协议包、Keychain 与 Bridge 客户端

**Files:**
- Create: `ios/Package.swift`
- Create: `ios/Sources/JarvisProtocol/BridgeModels.swift`
- Create: `ios/Sources/JarvisProtocol/RequestSigner.swift`
- Create: `ios/Sources/JarvisCore/KeychainDeviceStore.swift`
- Create: `ios/Sources/JarvisCore/BridgeClient.swift`
- Create: `ios/Tests/JarvisProtocolTests/BridgeModelsTests.swift`
- Create: `ios/Tests/JarvisProtocolTests/RequestSignerTests.swift`
- Create: `ios/Tests/JarvisCoreTests/BridgeClientTests.swift`

**Interfaces:**
- Produces: Swift `BridgeRequest: Codable`, `BridgeResponse: Codable`, `TaskState`, `RequestSigner.signature(for:secret:)`, `PinnedCertificateDelegate`, `BridgeClient.submit(_:) async throws -> BridgeResponse`.
- Consumes: the exact JSON field names and canonicalization rules from Task 1.

- [ ] **Step 1: Write failing canonical JSON parity test**

```swift
@Test func canonicalPayloadMatchesPythonFixture() throws {
    let request = Fixtures.openWeChatRequest
    #expect(try request.canonicalData() == Fixtures.openWeChatCanonicalJSON.data(using: .utf8))
}
```

- [ ] **Step 2: Run Swift tests on Codemagic/macOS and verify RED**

Run: `cd ios && swift test`

Expected: FAIL because source targets do not exist.

- [ ] **Step 3: Implement Codable models and CryptoKit HMAC**

Use sorted JSON keys and the same UTF-8 canonical payload as Python. Never use localized display strings as protocol enum values.

- [ ] **Step 4: Write failing Keychain, certificate pinning and URLProtocol client tests**

```swift
@Test func duplicateSensitiveRequestIsNotAutomaticallyRetried() async throws {
    let transport = RecordingTransport(results: [.timedOut])
    let client = BridgeClient(transport: transport, retryPolicy: .safeReadsOnly)
    await #expect(throws: BridgeError.resultUnknown) {
        try await client.submit(Fixtures.sendMessageRequest)
    }
    #expect(transport.requests.count == 1)
}
```

- [ ] **Step 5: Implement Keychain storage and no-retry sensitive transport**

Store device ID, device secret and Bridge certificate fingerprint using `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `PinnedCertificateDelegate` must reject any server certificate whose DER SHA-256 fingerprint differs from the scanned pairing value. Retry only read-only status requests; tool submissions with unknown results return `.resultUnknown`.

- [ ] **Step 6: Run tests and commit**

Run: `cd ios && swift test`

Expected: PASS on the cloud macOS runner.

```bash
git add ios/Package.swift ios/Sources ios/Tests
git commit -m "feat: add Swift Jarvis bridge client"
```

---

### Task 5: SwiftUI 极夜黑首页、任务与设备界面

**Files:**
- Create: `ios/project.yml`
- Create: `ios/JarvisIOS/App/JarvisIOSApp.swift`
- Create: `ios/JarvisIOS/App/AppModel.swift`
- Create: `ios/JarvisIOS/Design/JarvisTheme.swift`
- Create: `ios/JarvisIOS/Conversation/ConversationView.swift`
- Create: `ios/JarvisIOS/Conversation/VoiceOrb.swift`
- Create: `ios/JarvisIOS/Tasks/TaskListView.swift`
- Create: `ios/JarvisIOS/Devices/DeviceView.swift`
- Create: `ios/JarvisIOS/Confirmation/ActionPreviewSheet.swift`
- Create: `ios/JarvisIOSUITests/ConversationUITests.swift`

**Interfaces:**
- Consumes: `BridgeClient` and protocol models from Task 4.
- Produces: three-tab SwiftUI shell, observable `AppModel`, explicit action-preview sheet.

- [ ] **Step 1: Write failing UI tests for the approved A layout**

```swift
func testHomeShowsConnectionVoiceComposerAndThreeTabs() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-fixture", "connected"]
    app.launch()
    XCTAssertTrue(app.staticTexts["电脑已连接"].exists)
    XCTAssertTrue(app.buttons["开始说话"].exists)
    XCTAssertTrue(app.textFields["输入消息"].exists)
    XCTAssertEqual(app.tabBars.buttons.count, 3)
}
```

- [ ] **Step 2: Generate project and verify RED on Codemagic**

Run: `cd ios && xcodegen generate && xcodebuild test -project JarvisIOS.xcodeproj -scheme JarvisIOS -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because app views do not exist.

- [ ] **Step 3: Implement the A「对话优先」shell**

Use system black as the dominant OLED surface, white primary text and semantic secondary/status colors. The home hierarchy is connection header → voice core → conversation → computer status → composer → `对话/任务/设备` tabs.

- [ ] **Step 4: Implement explicit states and confirmation sheet**

`AppModel.Phase` must include `.idle`, `.listening`, `.transcribing`, `.thinking`, `.awaitingConfirmation(ActionPreview)`, `.executing`, `.completed`, `.failed`, `.offline` and `.resultUnknown`. Every state has visible text; color is never the only indicator.

- [ ] **Step 5: Add UI tests for offline, confirmation, cancellation and result unknown**

Confirm that recipient and full message are visible before the allow button. Cancel must dismiss without calling the client. Result unknown must show “不要重复发送，请检查目标应用”.

- [ ] **Step 6: Run simulator tests and commit**

Run the Task 5 `xcodebuild test` command.

Expected: PASS.

```bash
git add ios/project.yml ios/JarvisIOS ios/JarvisIOSUITests
git commit -m "feat: build Jarvis iPhone conversation UI"
```

---

### Task 6: 语音、Siri、操作按钮与 Widget

**Files:**
- Create: `ios/JarvisIOS/Voice/SpeechSession.swift`
- Create: `ios/JarvisIOS/Voice/SpeechPermissionView.swift`
- Create: `ios/JarvisIntents/StartJarvisIntent.swift`
- Create: `ios/JarvisIntents/JarvisShortcuts.swift`
- Create: `ios/JarvisWidget/JarvisWidget.swift`
- Create: `ios/JarvisWidget/JarvisControl.swift`
- Create: `ios/Tests/JarvisCoreTests/SpeechSessionTests.swift`
- Modify: `ios/project.yml`

**Interfaces:**
- Produces: `SpeechSession.start()`, `SpeechSession.stop() async throws -> String`, `StartJarvisIntent`, lock-screen/home widget and Control Widget entry.
- Consumes: `AppModel.submit(text:)` from Task 5.

- [ ] **Step 1: Write failing speech-state tests**

```swift
@Test func uncertainTranscriptNeverAutoExecutes() async throws {
    let recognizer = FakeRecognizer(result: .init(text: "给宋…", confidence: 0.42))
    let session = SpeechSession(recognizer: recognizer, minimumConfidence: 0.70)
    let result = try await session.stop()
    #expect(result.requiresReview)
    #expect(result.executableText == nil)
}
```

- [ ] **Step 2: Verify RED, then implement AVAudioEngine + Speech**

Request microphone and speech recognition permissions only when the user starts voice. Keep a visible listening state. Stop and release the audio engine when the app resigns active.

- [ ] **Step 3: Implement App Intent and App Shortcuts phrases**

Expose “启动 Jarvis” and “开始与 Jarvis 对话”. The intent opens the app directly into the listening-ready screen; it does not start hidden background recording.

- [ ] **Step 4: Implement lock-screen/home widget and Control Widget**

All entries deep-link to `jarvis://listen`. Widgets display connection status from an App Group snapshot but never store device secrets in the App Group container.

- [ ] **Step 5: Run unit and simulator tests**

Run: `cd ios && swift test`

Run the Task 5 `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisIOS/Voice ios/JarvisIntents ios/JarvisWidget ios/Tests ios/project.yml
git commit -m "feat: add Jarvis voice and iOS entry points"
```

---

### Task 7: Codemagic 无签名构建与测试

**Files:**
- Create: `codemagic.yaml`
- Create: `scripts/ci/verify-ios-project.sh`
- Create: `docs/ios-cloud-build.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: XcodeGen project and test schemes from Tasks 4–6.
- Produces: reproducible unsigned simulator build, JUnit/XCResult artifacts and later opt-in signed TestFlight workflow.

- [ ] **Step 1: Add a failing CI preflight**

`verify-ios-project.sh` must fail when `ios/project.yml`, required schemes, bundle identifiers or test targets are missing. It must print one actionable error per missing input.

- [ ] **Step 2: Run preflight locally where possible and verify expected failure**

Run: `bash scripts/ci/verify-ios-project.sh`

Expected before configuration: non-zero exit naming the first missing scheme or identifier.

- [ ] **Step 3: Add unsigned Codemagic workflow**

Configure a native iOS workflow on an Apple Silicon macOS instance to install XcodeGen, generate the project, run `swift test`, run simulator `xcodebuild test` with `CODE_SIGNING_ALLOWED=NO`, and collect `.xcresult` plus JUnit output.

- [ ] **Step 4: Add disabled-by-default TestFlight workflow**

The signed workflow must require a Codemagic input `submit_to_testflight: true` and the App Store Connect integration. No `.p8`, certificate, profile or password may appear in repository files.

- [ ] **Step 5: Document account handoff**

Document the exact future steps: join Apple Developer Program, create App ID and App Store Connect app, create a dedicated API key, store it in Codemagic integration, run a signed build, then add the build to an internal TestFlight group.

- [ ] **Step 6: Trigger cloud build and verify artifacts**

Expected: unsigned compilation and all tests PASS; no signing attempt occurs. Preserve the build URL and artifact names in the handoff notes.

- [ ] **Step 7: Commit**

```bash
git add codemagic.yaml scripts/ci/verify-ios-project.sh docs/ios-cloud-build.md .gitignore
git commit -m "ci: build Jarvis iOS with Codemagic"
```

---

### Task 8: 同一 Wi‑Fi 端到端验收

**Files:**
- Create: `tests/integration/test_bridge_mobile_flow.py`
- Create: `docs/ios-acceptance-checklist.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: complete Bridge API, Swift client behavior and Codemagic build.
- Produces: executable acceptance checklist and automated protocol-level end-to-end coverage.

- [ ] **Step 1: Write failing end-to-end protocol test**

The test creates a pairing session, claims an iPhone device, signs an `open_application` request, verifies completion, submits a WeChat request, verifies `awaiting_confirmation`, confirms it once, and verifies a duplicate confirm does not call the sender twice.

- [ ] **Step 2: Run test and verify RED**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest tests/integration/test_bridge_mobile_flow.py -q`

Expected: FAIL until all Task 1–3 interfaces are wired together.

- [ ] **Step 3: Add only the integration wiring required to pass**

Use in-memory credential and fake tool adapters. Do not open real applications or send real messages in automated tests.

- [ ] **Step 4: Write manual LAN acceptance checklist**

Include: QR pairing, reconnect after app restart, Wi‑Fi change, computer offline, open existing WeChat, message preview/cancel, one approved test message, lost response, revoked device, cloud fallback refusal and permission denial.

- [ ] **Step 5: Run final verification**

Run: `$env:PYTHONPATH='src'; G:\python.exe -m pytest -q`

Run: `G:\python.exe -m ruff check src tests`

Run on Codemagic: `cd ios && swift test` and simulator `xcodebuild test`.

Expected: every suite PASS; signed distribution remains disabled until the developer membership and credentials exist.

- [ ] **Step 6: Commit**

```bash
git add tests/integration/test_bridge_mobile_flow.py docs/ios-acceptance-checklist.md README.md
git commit -m "test: verify Jarvis iPhone LAN workflow"
```
