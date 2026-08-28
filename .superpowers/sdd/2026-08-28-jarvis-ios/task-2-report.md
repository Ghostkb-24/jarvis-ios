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

## Fix round 1 — concurrency, monotonic revocation, LAN validation, credential length

### Implementation

- Made pairing claim consumption atomic with a per-session lock. Proof and
  expiry validation remain outside the critical section, while the claimed
  check, device ID/secret generation, and claimed-state transition are performed
  together. A deterministic two-thread test synchronizes both valid proof
  comparisons before the transition and proves exactly one claim succeeds.
- Made device revocation monotonic. `save` and `revoke` use `BEGIN IMMEDIATE` so
  concurrent stores serialize metadata inspection, credential mutation, and the
  SQLite state transition. A stale save observing a revoked row preserves it,
  performs no credential write, and removes any unexpectedly remaining
  credential.
- Restricted pairing URLs to HTTPS URLs without embedded credentials whose host
  is loopback, link-local, RFC1918/ULA private address space, localhost, `.local`,
  or a single-label LAN hostname. Certificate fingerprints must be exactly 64
  lowercase hexadecimal characters.
- Restricted requested TLS SAN hosts to the same private/local host classes and
  verify on reload that every requested host exists in the established public
  certificate SAN extension. Missing coverage fails closed without rotation.
- Device credentials now decode only when Base64 is valid and the decoded secret
  is exactly 32 bytes.

### RED / GREEN evidence

#### Atomic one-time claim

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py::test_simultaneous_claims_allow_exactly_one_success -q
```

RED output:

```text
F                                                                        [100%]
AssertionError: assert 2 == 1
1 failed in 0.21s
```

GREEN output after locking the state transition:

```text
.                                                                        [100%]
1 passed in 0.13s
```

#### Monotonic revocation

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_device_store.py::test_stale_save_cannot_reactivate_revoked_device -q
```

RED output:

```text
F                                                                        [100%]
assert False is True
1 failed in 0.29s
```

GREEN output after transactional stale-save protection:

```text
.                                                                        [100%]
1 passed in 0.17s
```

#### Private URL, fingerprint, and SAN consistency

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py::test_create_rejects_non_https_or_non_private_bridge_url tests\bridge\test_pairing.py::test_create_rejects_malformed_certificate_fingerprint tests\bridge\test_tls.py::test_creation_rejects_public_certificate_host tests\bridge\test_tls.py::test_reload_rejects_requested_host_missing_from_certificate_sans -q
```

RED output:

```text
FFFFFFFFFF                                                               [100%]
10 failed in 0.52s
```

GREEN output after constructor and reload validation:

```text
..........                                                               [100%]
10 passed in 0.29s
```

#### Credential decoding and exact length

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_device_store.py::test_get_secret_returns_none_for_invalid_base64_credential tests\bridge\test_device_store.py::test_get_secret_returns_none_for_wrong_length_credential -q
```

RED output (invalid Base64 was already fail-closed; both valid wrong-length cases
exposed the missing boundary):

```text
.FF                                                                      [100%]
2 failed, 1 passed in 0.44s
```

GREEN output after the exact 32-byte requirement:

```text
...                                                                      [100%]
3 passed in 0.24s
```

### Final verification

Focused Bridge tests, rerun after the final import-only lint correction:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge -q
```

```text
.................................................                        [100%]
49 passed in 0.87s
```

One full Python test run for the fix round:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest -q
```

```text
........................................................................ [ 64%]
.......................................                                  [100%]
111 passed in 11.69s
```

Ruff initially reported one import-block spacing issue. After that mechanical
correction, the fresh command and output were:

```powershell
& 'G:\venv\Scripts\python.exe' -m ruff check src tests
```

```text
All checks passed!
```

### Files changed in fix round 1

- `src/jarvis_assistant/bridge/pairing.py`
- `src/jarvis_assistant/bridge/device_store.py`
- `src/jarvis_assistant/bridge/tls.py`
- `tests/bridge/test_pairing.py`
- `tests/bridge/test_device_store.py`
- `tests/bridge/test_tls.py`
- `.superpowers/sdd/2026-08-28-jarvis-ios/task-2-report.md`

### Self-review and concerns

- The concurrent-claim test widens the original race deterministically at the
  proof-comparison boundary without adding production test hooks.
- SQLite `BEGIN IMMEDIATE` provides cross-connection ordering for save/revoke;
  credential operations occur while the write reservation is held so the final
  operation determines whether the credential exists.
- LAN DNS classification is necessarily syntactic at this layer. `.local` and
  single-label names are allowed for same-Wi-Fi use, while dotted public DNS
  names and public IP ranges are rejected. No DNS resolution, discovery, or
  listener behavior was added.
- The previously documented cross-system transaction limitation remains: a
  credential backend failure cannot be made atomically transactional with
  SQLite. Exceptions roll back SQLite, and subsequent reads still fail closed.

## Fix round 2 — legacy IPv4 encodings and trailing-dot canonicalization

### Implementation

- Hardened the shared private-host classifier against legacy IPv4 encodings.
  Dotless all-decimal hosts and `0x`-prefixed hexadecimal hosts are rejected
  before the LAN hostname fallback, covering forms such as `134744072` and
  `0x08080808` that legacy resolvers interpret as public `8.8.8.8`.
- Added one shared host canonicalizer for pairing and TLS. IP literals use the
  canonical `ipaddress` representation; DNS names are lowercase without a
  trailing root dot.
- Pairing now stores and advertises the canonical host in its HTTPS QR URL.
- TLS canonicalizes supplied hosts before certificate SAN construction and uses
  that same representation for established-certificate comparison. Creating and
  reloading an identity requested as `bridge.local.` therefore stores
  `bridge.local` in the SAN and preserves the certificate fingerprint.

### RED / GREEN evidence

#### Legacy numeric public IPv4 encodings

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py::test_create_rejects_non_https_or_non_private_bridge_url tests\bridge\test_tls.py::test_creation_rejects_public_certificate_host -q
```

RED output:

```text
..FF...FF.                                                               [100%]
4 failed, 6 passed in 0.40s
```

The four failures were the URL and TLS cases for `134744072` and
`0x08080808`. GREEN after rejecting legacy numeric syntax:

```text
..........                                                               [100%]
10 passed in 0.19s
```

#### Stable trailing-dot TLS identity

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_tls.py::test_trailing_dot_host_is_canonicalized_and_reloads_stably -q
```

RED output:

```text
F                                                                        [100%]
AssertionError: assert 'bridge.local' in ['localhost', 'bridge.local.']
1 failed in 0.32s
```

GREEN after canonicalizing before SAN construction and comparison:

```text
.                                                                        [100%]
1 passed in 0.27s
```

#### Pairing URL/certificate host consistency

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py::test_create_canonicalizes_trailing_dot_bridge_url -q
```

RED output:

```text
F                                                                        [100%]
AssertionError: assert 'https://bridge.local.:8443' == 'https://bridge.local:8443'
1 failed in 0.26s
```

GREEN command covering both advertised URL and stable TLS reload:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_pairing.py::test_create_canonicalizes_trailing_dot_bridge_url tests\bridge\test_tls.py::test_trailing_dot_host_is_canonicalized_and_reloads_stably -q
```

```text
..                                                                       [100%]
2 passed in 0.31s
```

### Final verification

Focused Bridge tests:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge -q
```

```text
.......................................................                  [100%]
55 passed in 1.02s
```

One full Python suite run:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest -q
```

```text
........................................................................ [ 61%]
.............................................                            [100%]
117 passed in 12.46s
```

Ruff:

```powershell
& 'G:\venv\Scripts\python.exe' -m ruff check src tests
```

```text
All checks passed!
```

### Files changed in fix round 2

- `src/jarvis_assistant/bridge/pairing.py`
- `src/jarvis_assistant/bridge/tls.py`
- `tests/bridge/test_pairing.py`
- `tests/bridge/test_tls.py`
- `.superpowers/sdd/2026-08-28-jarvis-ios/task-2-report.md`

### Self-review and concerns

- Decimal-only detection also rejects leading-zero decimal/octal-looking
  dotless forms; the hexadecimal rule is case-insensitive after canonicalization.
  Non-canonical dotted numeric forms remain rejected by the existing dotted
  public-host rule.
- Host canonicalization occurs before both QR serialization and X.509 SAN
  construction, preventing future representation drift between connection and
  pinning data.
- LAN DNS classification remains syntactic; no DNS lookup, listener, or public
  discovery behavior was introduced.

## Fix round 3 — legacy trailing-dot SAN migration

### Implementation

- Canonicalize DNS SAN values read from established certificates with the same
  host canonicalizer used for requested hosts and newly created certificates.
- Existing pre-fix identities whose certificate contains `bridge.local.` now
  satisfy a request for canonical `bridge.local` without rewriting the public
  certificate, replacing the credential-backed private key, or changing the
  pinned SHA-256 fingerprint.
- Added a migration regression that builds a real RSA/SHA-256 self-signed legacy
  certificate containing the literal trailing-dot SAN, persists its public
  certificate and test-local credential, and loads it through the current path.

### RED / GREEN evidence

RED command:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge\test_tls.py::test_reload_migrates_legacy_trailing_dot_san_without_rotation -q
```

RED output:

```text
F                                                                        [100%]
jarvis_assistant.bridge.tls.BridgeTLSIdentityError:
TLS certificate SAN does not cover requested hosts
1 failed in 0.35s
```

GREEN after canonicalizing DNS SANs during established-certificate comparison:

```text
.                                                                        [100%]
1 passed in 0.30s
```

### Final verification

Focused Bridge tests:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest tests\bridge -q
```

```text
........................................................                 [100%]
56 passed in 1.29s
```

One full Python suite run:

```powershell
& 'G:\venv\Scripts\python.exe' -m pytest -q
```

```text
........................................................................ [ 61%]
..............................................                           [100%]
118 passed in 12.52s
```

Ruff:

```powershell
& 'G:\venv\Scripts\python.exe' -m ruff check src tests
```

```text
All checks passed!
```

### Files changed in fix round 3

- `src/jarvis_assistant/bridge/tls.py`
- `tests/bridge/test_tls.py`
- `.superpowers/sdd/2026-08-28-jarvis-ios/task-2-report.md`

### Self-review and concerns

- Migration comparison changes only the in-memory SAN key used for matching;
  certificate and credential persistence paths are untouched, so the stable
  identity is not rotated or rewritten.
- The existing fail-closed behavior remains for genuinely missing SAN coverage,
  corrupt certificates, missing keys, and key/certificate mismatches.
