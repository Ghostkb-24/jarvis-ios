# Final branch blocker fix report

Date: 2026-09-02 (Asia/Shanghai)

## Status

The final review's Critical blockers are addressed in two reproducible commits:

- `232eaf6` — SQLite bridge compatibility and committed iOS CI prerequisites.
- `4b70dc9` — production iOS bridge bootstrap, explicit pairing UI, and the
  interoperable desktop/iOS pairing contract.

The unrelated untracked Task 7 brief and review files were preserved and were
not included in either commit.

## Fixes

### SQLite and CI

- `SQLiteStore` now exposes the shared re-entrant lock expected by bridge
  components and migrates existing databases to `paired_devices` schema
  version 2.
- Regression tests cover the lock alias and a version-1 database migration.
- The signed-build version script, iOS project version settings, generated
  project preflight checks, and their tests are committed rather than only
  referenced by CI/report prose.

### Production iOS runtime

- Non-UI-test launch now attempts to load endpoint metadata from `UserDefaults`,
  credentials from `KeychainDeviceStore`, and construct a pinned
  `BridgeClient`.
- A launch without complete saved configuration is explicitly unpaired. It no
  longer presents a paired snapshot backed by a nil client.
- `DeviceView` exposes a pairing payload field and action. A successful claim
  stores only endpoint metadata in defaults, keeps device credentials in the
  Keychain store, installs the live client, and updates connection state.

### Pairing wire contract

- The shared QR fixture is
  `ios/Tests/JarvisProtocolTests/Fixtures/pairing-payload.json`.
- Desktop `PairingSession.qr_payload` and Swift `PairingPayload` now use the
  same seven fields: `version`, `bridge_id`, `bridge_url`,
  `certificate_sha256`, `session_id`, `expires_at`, and `proof`.
- Both Swift pairing entry points POST a strict claim body to the single
  `/v1/pair/claim` endpoint. The claim carries `session_id`, `device_name`,
  `proof`, and a client-generated Curve25519 public-key binding.
- The desktop remains authoritative for the device ID and returns that ID,
  the echoed public-key binding, and a 32-byte URL-safe base64 secret. Swift
  verifies the key binding and secret length before saving credentials.
- The removed `/v1/pair/challenge` HTTP route is covered by a rejection test so
  the two incompatible contracts cannot silently reappear.

### Important review items

- The event broker retains a bounded latest-event replay. A subscriber that
  connects after a terminal publish receives that event rather than waiting
  forever; duplicate replay of the current state is suppressed.
- Desktop bridge URLs now reject credentials, public hosts, non-root paths,
  query strings, and fragments, matching the existing Swift endpoint policy.

## Verification

All Python commands ran from the `jarvis-ios` worktree with Python 3.12.8.

- Focused LAN/pairing suite:
  `G:\venv\Scripts\python.exe -m pytest tests/test_lan_bridge.py tests/bridge/test_pairing.py -q --basetemp=.pytest-pairing`
  — `35 passed, 1 warning`.
- Full Python suite:
  `G:\venv\Scripts\python.exe -m pytest --basetemp=.pytest-report -ra`
  — `217 passed, 1 warning in 23.56s`.
- Static Python checks:
  `G:\venv\Scripts\python.exe -m ruff check src tests`
  — `All checks passed!`.
- Patch hygiene: `git diff --check` — passed.
- CI shell syntax: `bash -n scripts/ci/verify-ios-project.sh` and
  `bash -n scripts/ci/set-ios-version.sh` — passed before commit `232eaf6`.

The one warning is Starlette's deprecation notice for importing TestClient
through FastAPI; it is unrelated to these changes.

## Remaining validation and concerns

- `swift`, `xcodebuild`, and XcodeGen are unavailable on this Windows host, so
  the Swift package tests, iOS unit/UI tests, and simulator build were not run
  locally. Codemagic/macOS must run the committed Swift gates before release.
- The explicit pairing action currently accepts the QR JSON payload by paste;
  native camera scanning remains a UX follow-up, not a wire-contract blocker.
- Event replay is in-memory and retains only the latest event for at most 1024
  request IDs. Durable reconnect cursors are outside this LAN bridge scope.
- No Codemagic build, XCResult/JUnit artifact, signed IPA, or TestFlight upload
  was produced in this worktree.
