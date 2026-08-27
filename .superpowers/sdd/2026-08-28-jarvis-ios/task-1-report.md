# Task 1 — Shared bridge protocol and authentication

## Implementation

- Added a versioned, strict Python bridge protocol in `src/jarvis_assistant/bridge/protocol.py`.
  - `BridgeRequest` is frozen, forbids unknown fields, validates the required non-empty identifiers, and serializes its HMAC input with the specified ASCII, sorted, compact JSON representation.
  - `BridgeResponse`, `TaskState`, and `Risk` cover the protocol states and the two allowed risk classifications without introducing execution, networking, pairing, or retry behavior.
- Added `src/jarvis_assistant/bridge/auth.py`.
  - `sign_request` returns lowercase HMAC-SHA256 hexadecimal signatures.
  - `verify_request` uses `hmac.compare_digest`, accepts only UTC timestamps, rejects invalid signatures, requests older than 300 seconds, and requests more than 30 seconds in the future.
  - No keys are persisted or logged.
- Re-exported the public protocol/auth interfaces from `jarvis_assistant.bridge`.
- Added focused canonical-payload and authentication tests. No `pyproject.toml` change was required because Pydantic was already a direct dependency.

## RED / GREEN evidence

1. Canonical payload RED:

   ```text
   ModuleNotFoundError: No module named 'jarvis_assistant.bridge'
   ```

   GREEN after implementing the minimal protocol model:

   ```text
   2 passed in 0.12s
   ```

2. Authentication RED:

   ```text
   ModuleNotFoundError: No module named 'jarvis_assistant.bridge.auth'
   ```

   GREEN after implementing signing and verification:

   ```text
   7 passed in 0.09s
   ```

## Final verification

Commands run from the task worktree:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge -q
& 'G:\venv\Scripts\python.exe' -m pytest -q
& 'G:\venv\Scripts\python.exe' -m ruff check src tests
```

Output:

```text
9 passed in 0.09s
71 passed in 8.43s
All checks passed!
```

## Files

- `src/jarvis_assistant/bridge/__init__.py`
- `src/jarvis_assistant/bridge/protocol.py`
- `src/jarvis_assistant/bridge/auth.py`
- `tests/bridge/test_protocol.py`
- `tests/bridge/test_auth.py`
- `.superpowers/sdd/2026-08-28-jarvis-ios/task-1-report.md`

## Self-review

- Canonical fixture matches the byte-for-byte required open-WeChat fixture.
- Request model is frozen and rejects unknown fields.
- Auth tests exercise real signing/verification code and cover matching signatures, payload tampering, expiry, future timestamps, malformed/non-UTC timestamps, and wrong secrets.
- Scope is limited to protocol and authentication primitives; it adds no server, pairing, storage, public networking, retry, Swift, or UI behavior.

## Concerns

- Pydantic's `frozen=True` makes model attributes immutable but, as in Pydantic generally, does not recursively make arbitrary `payload` dictionaries immutable. Signature verification always recomputes canonical bytes, so any post-sign mutation invalidates the prior signature.
