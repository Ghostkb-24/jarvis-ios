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

Review-round-1 TLS remediation commit:
`bf8f18d66e1cb07a8fbb5f81b9d7d4ec50c888d3`
(`fix: protect bridge TLS key before write`).

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

## Review round 1 — protected TLS materialization

The initial Task 3A implementation removed its temporary private-key file, but
the review correctly found two gaps: it wrote the key before hardening the
file's DACL and it attempted deletion only once.  The remediation now:

- ACL-hardens the newly created, empty file before the first private-key byte
  is written.  On Windows, `icacls` removes inheritance, grants only the
  current SID full control, and then runs its DACL verification command.  An
  ACL/verification error aborts materialization before writing.
- Retries deletion three times with a short bounded delay for sharing failures.
- If all deletion attempts fail, overwrites the file contents with zeroes,
  fsyncs, truncates to zero length, and registers bounded deferred cleanup at
  process exit.  If sanitization itself fails, startup/failure handling raises
  rather than silently leaving a private-key residual.

The code continues to pass through the original TLS load failure after a
successful sanitize, so the caller receives the real certificate-loading error
while the residual contains no key material.

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

### Review-round-1 RED/GREEN evidence

Before changing production code, four new TLS regressions were run against
`52b8c84`:

```text
4 failed, 16 passed in 1.48s
```

They independently demonstrated that the ACL hook saw a complete private key,
an ACL failure occurred after the write, one injected `PermissionError`
escaped cleanup, and permanent unlink failure replaced the original TLS-load
error while retaining private-key bytes.  The minimal remediation above made
the same focused TLS file green:

```text
20 passed in 1.42s
```

The final focused lifecycle plus Bridge run then passed 135 tests, and the
complete suite passed 184 tests.

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
| `py -3.12 -m pytest tests/bridge/test_tls.py -q --basetemp=.pytest-task3a-r1-red` | `4 failed, 16 passed in 1.48s` (expected RED) |
| `py -3.12 -m pytest tests/bridge/test_tls.py -q --basetemp=.pytest-task3a-r1-green-2` | `20 passed in 1.42s` |
| `py -3.12 -m pytest tests/test_app.py tests/bridge -q --basetemp=.pytest-task3a-r1-focused` | `135 passed in 17.29s` |
| `py -3.12 -m pytest -q --basetemp=.pytest-task3a-r1-full` | `184 passed in 17.75s` |
| `py -3.12 -m pip check` | `No broken requirements found.` |

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
  loads the private key.  It is ACL-protected before the write, and is removed
  before Uvicorn starts or sanitized to an empty file if sharing locks prevent
  immediate deletion; a fully memory-only key-loading API is not available in
  the standard-library `SSLContext` interface.
- This task intentionally makes no Swift/iOS Task 4+ changes and does not
  alter the SDD ledger.
