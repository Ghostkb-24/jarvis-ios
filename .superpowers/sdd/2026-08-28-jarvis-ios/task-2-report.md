# Task 2 — One-time QR pairing, device credentials, and TLS identity

## Implementation

- Added `PairingSession` and `PairedDevice` in
  `src/jarvis_assistant/bridge/pairing.py`.
  - Sessions use cryptographically random session IDs and one-time proofs with a
    120-second default TTL.
  - The QR payload contains only protocol version, Bridge identity and LAN HTTPS
    URL, certificate SHA-256 fingerprint, pairing session identity, expiry, and
    proof.
  - Claims validate a non-blank normalized display name, timezone-aware time,
    expiry (including the exact expiry boundary), replay, and proof via
    `hmac.compare_digest` over bytes so malformed Unicode input is rejected
    cleanly.
  - Long-lived device ID and 32-byte secret are generated only by a successful
    claim. Secret-bearing fields are excluded from object representations.
- Added the `CredentialBackend` protocol and `DeviceStore` in
  `src/jarvis_assistant/bridge/device_store.py`.
  - Device metadata is persisted in SQLite and device secrets are URL-safe
    base64-encoded only at the credential boundary under service
    `jarvis-bridge-device` and username equal to the device ID.
  - Unknown, revoked, missing, empty, or malformed stored credentials fail
    closed from `get_secret`.
  - Revocation marks the device revoked and removes any credential; repeating
    it for known or unknown devices is safe.
- Migrated `SQLiteStore` to schema version 2 with a `paired_devices` metadata
  table containing no secret column.
- Added stable self-signed TLS identity management in
  `src/jarvis_assistant/bridge/tls.py`.
  - First use creates an RSA-2048/SHA-256 self-signed certificate valid for 365
    days, with localhost, loopback, and caller-provided private/LAN SANs.
  - Only the public certificate is atomically persisted on disk. The PKCS#8
    private key is stored only through `CredentialBackend` under service
    `jarvis-bridge-tls` and username equal to the Bridge ID.
  - Reload validates certificate parsing, private-key parsing, key/certificate
    equality, and the self-signature before returning the same DER fingerprint.
    Missing, corrupt, partial, or mismatched established identities raise
    `BridgeTLSIdentityError` and are never silently rotated.
- Added `cryptography>=45,<47` as the required direct runtime dependency.

## RED / GREEN evidence

### Pairing

Initial RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py -q
```

RED output:

```text
ModuleNotFoundError: No module named 'jarvis_assistant.bridge.pairing'
1 error in 0.23s
```

GREEN after the minimum pairing implementation:

```text
.......                                                                  [100%]
7 passed in 0.12s
```

Self-review boundary RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py::test_claim_rejects_expired_session tests\bridge\test_pairing.py::test_claim_rejects_bad_proof_without_consuming_session -q
```

RED output:

```text
F.F                                                                      [100%]
FAILED tests/bridge/test_pairing.py::test_claim_rejects_expired_session
  Failed: DID NOT RAISE PairingClaimError
FAILED tests/bridge/test_pairing.py::test_claim_rejects_bad_proof_without_consuming_session[é]
  TypeError: comparing strings with non-ASCII characters is not supported
2 failed, 1 passed in 0.20s
```

GREEN after exact-boundary rejection and byte-wise constant-time comparison:

```text
...                                                                      [100%]
3 passed in 0.11s
```

### Device store

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_device_store.py -q
```

RED output:

```text
ModuleNotFoundError: No module named 'jarvis_assistant.bridge.device_store'
1 error in 0.25s
```

GREEN output:

```text
......                                                                   [100%]
6 passed in 0.32s
```

### TLS identity

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_tls.py -q
```

RED output:

```text
ModuleNotFoundError: No module named 'jarvis_assistant.bridge.tls'
1 error in 0.35s
```

GREEN output:

```text
........                                                                 [100%]
8 passed in 0.50s
```

## Final verification

Focused Bridge tests (fresh after the final import-only lint correction):

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge -q
```

```text
..................................                                       [100%]
34 passed in 0.80s
```

Full Python suite:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest -q
```

```text
........................................................................ [ 75%]
........................                                                 [100%]
96 passed in 12.03s
```

Ruff initially identified only two import organization findings. After the
mechanical import correction, the fresh command was:

```powershell
& 'G:\venv\Scripts\python.exe' -m ruff check src tests
```

```text
All checks passed!
```

## Files

- `src/jarvis_assistant/bridge/pairing.py`
- `src/jarvis_assistant/bridge/device_store.py`
- `src/jarvis_assistant/bridge/tls.py`
- `src/jarvis_assistant/storage.py`
- `tests/bridge/test_pairing.py`
- `tests/bridge/test_device_store.py`
- `tests/bridge/test_tls.py`
- `pyproject.toml`
- `.superpowers/sdd/2026-08-28-jarvis-ios/task-2-report.md`

## Self-review

- Tests exercise real pairing, SQLite, certificate, key, and fingerprint
  behavior using only test-local in-memory credential backends; the Windows
  Credential Manager is never accessed.
- Pairing tests cover successful one-time claim, replay, exact expiry, bad ASCII
  and Unicode proofs, blank names, and the complete QR payload without any
  long-lived secret.
- Device tests cover metadata/secret retrieval, process-style store reload,
  revocation, repeated revocation, missing credentials, and raw/hex/base64
  secret scans over both rows and database bytes.
- TLS tests cover first creation, SAN and validity properties, stable reload,
  independently calculated DER fingerprint, public-only certificate files,
  corrupt certificates, mismatched keys, and missing/corrupt private keys.
- The task adds no HTTP endpoints, public listener, discovery, execution,
  retry, cloud, UI, Swift, or iOS behavior.

## Concerns

- SQLite, the OS credential backend, and public-certificate file storage cannot
  form one cross-system transaction. The creation order minimizes disk exposure,
  and any partial established TLS state fails closed on the next load rather
  than rotating the pinned identity. Device secret lookup likewise fails closed
  if either metadata or its credential is missing.
