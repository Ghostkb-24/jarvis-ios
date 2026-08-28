# Task 3A Report — Production Lifecycle Hardening

## Result

Task 3A closes the four lifecycle blockers from the Task 3 review.  The
production composition now retains the exact controller and pairing owner that
it starts; TLS is loaded into an in-memory `SSLContext` from a user-protected
temporary key file and the file is always removed; shutdown is asynchronous and
retryable; and the pairing menu renders a scannable QR without displaying the
proof as text.

Implementation commit: `87802a4bfc4e511fc12cddc9c6638ed0b57ae00d`
(`fix: harden bridge production lifecycle`).

## Blockers closed

### A. Controller ownership

- `MobileBridgeComposition` returns both the controller and the
  `PairingSessionOwner`.
- `build_application()` assigns both to `ApplicationRuntime` before calling
  `controller.start()`.  Tray stop and shutdown therefore retain and operate
  on the same controller instance.
- The fake-driven composition regression proves compose -> start ->
  stop/join -> SQLite close ordering.

### B. TLS private-key lifecycle

- `BridgeTLSIdentity` remains the private-key authority through the credential
  backend.  `_compose_mobile_bridge()` never writes `bridge-key.pem`.
- `create_server_ssl_context()` makes a uniquely named temporary key file,
  applies mode `0600`, applies a Windows current-user-only ACL (SID resolved
  with `whoami` and set with `icacls`), loads the chain, and unlinks it in a
  `finally` block on success and all load failures.
- `BridgeServerController` receives the preloaded context through Uvicorn's
  context factory, so Uvicorn receives no private-key filename.  Tests cover
  normal context loading, TLS-load failure, production composition, controller
  start failure, tray stop, and application shutdown.

### C. Retryable asynchronous shutdown and quit ordering

- Server stop/join executes through `WorkerTask`, never in the Qt UI thread.
- A join exception resets `_shutting_down`, leaves the controller and SQLite
  store available, and surfaces the error.  A subsequent shutdown retries the
  same controller.
- Only successful server completion reaches resource cleanup, SQLite close,
  then `QApplication.quit()`.

### D. Refreshable synchronized pairing QR

- `PairingSessionOwner` holds the single current session.  It creates one for
  the first display, preserves it while live, and rotates it after expiry or a
  successful claim.
- `BridgeService.claim_pairing()` delegates to that same owner, keeping the
  displayed QR and claim endpoint synchronized.
- `PairingQrDialog` renders the serialized payload as a QR pixmap; the proof
  is never put in sidebar status, dialog labels, log output, or audit fields.

## TDD evidence

The inherited Task 3A worktree contained RED/GREEN basetemp evidence for the
earlier controller-ownership, TLS-composition, and shutdown regressions.  On
handoff, the focused lifecycle run exposed two remaining real integration REDs:
the production composition did not accept an injectable controller factory,
causing the tray-stop and shutdown TLS regressions to fail with
`TypeError: _compose_mobile_bridge() got an unexpected keyword argument
'controller_factory'`.  The same run also exposed a test-support omission
(`pytest` import), which was corrected before exercising the behavior.

Minimal GREEN was adding the `controller_factory` dependency-injection seam to
`_compose_mobile_bridge()`; the three affected tests then passed:

```text
3 passed in 2.65s
```

The final focused lifecycle and Bridge run passed 132 tests, including the
controller ownership, TLS cleanup, retry/quit ordering, QR rendering, session
rotation, and service-synchronization regressions.

## Verification

All commands ran from
`C:\Users\Administrator\Documents\ChatGPT\工作项目\.worktrees\jarvis-ios`
with `PYTHONPATH=src` and Python `py -3.12`.

| Command | Result |
| --- | --- |
| `py -3.12 -m pytest tests/test_app.py -q --basetemp=.pytest-task3a-green-app-full` | `24 passed in 14.83s` |
| `py -3.12 -m pytest tests/test_app.py tests/bridge -q --basetemp=.pytest-task3a-focused-final` | `132 passed in 15.80s` |
| `py -3.12 -m pytest -q --basetemp=.pytest-verify-final` | `181 passed in 17.91s` |
| `py -3.12 -m ruff check src tests` | `All checks passed!` |
| `git diff --check` | passed (no whitespace errors) |
| `git diff --cached --check` | passed before the implementation commit |
| `git show --check --oneline HEAD` | passed for the prior base commit; implementation commit was then created from an already checked index |

The task-specific pytest basetemp directories were inspected to contain only
pytest outputs (temporary SQLite databases, test certificates, and test files)
and removed after verification; no private-key temp file was retained.

## Files changed

- `pyproject.toml`
- `src/jarvis_assistant/app.py`
- `src/jarvis_assistant/bridge/pairing.py`
- `src/jarvis_assistant/bridge/server.py`
- `src/jarvis_assistant/bridge/service.py`
- `src/jarvis_assistant/bridge/tls.py`
- `src/jarvis_assistant/ui/pairing.py`
- `tests/test_app.py`
- `tests/bridge/test_pairing.py`
- `tests/bridge/test_server.py`
- `tests/bridge/test_service.py`
- `tests/bridge/test_tls.py`

## Remaining concerns

- The temporary file necessarily exists briefly while Python's SSL library
  loads the private key.  It is current-user ACL protected on Windows and is
  removed before Uvicorn starts; a fully memory-only key-loading API is not
  available in the standard-library `SSLContext` interface.
- This task intentionally makes no Swift/iOS Task 4+ changes and does not
  alter the SDD ledger.
