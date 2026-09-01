# SQLite Thread Isolation Fix Report

## Root cause

`SQLiteStore.open()` created one default `sqlite3.Connection` on the UI thread.
The application sends orchestration work to `QThreadPool`, while settings and audit
storage share that same store. Python's default SQLite setting is
`check_same_thread=True`, so a bridge or device-store worker that used the shared
connection raised `sqlite3.ProgrammingError` instead of completing its persistence
work.

## RED

Added `test_file_store_isolates_connections_for_concurrent_settings_and_audit_work`.
It starts one settings/bridge worker and two device/audit workers against one real
file database, checks the worker thread identities and connection identities, and
checks every worker connection has WAL and a 5000 ms busy timeout.

Before the implementation, the focused test failed as expected:

```text
sqlite3.ProgrammingError: SQLite objects created in a thread can only be used in that same thread.
```

The failure occurred in `SQLiteStore.save_settings()` when the background worker
attempted to use the connection created by `SQLiteStore.open()` on the main thread.

## GREEN

`SQLiteStore.open()` now initializes a file-backed store with thread-local
connections. The first access on each thread creates that thread's own normal
SQLite connection, sets `sqlite3.Row`, enables WAL, and sets `busy_timeout` to
5000 ms. Store migration and each store read/write transaction are protected by
one reentrant store lock. Direct construction with an injected connection remains
supported and is covered by a regression test.

## Verification

```text
PYTHONPATH=src G:\python.exe -m pytest tests/test_storage.py -q
5 passed in 0.19s

PYTHONPATH=src G:\python.exe -m ruff check src tests
All checks passed!

PYTHONPATH=src G:\python.exe -m pytest -q
64 passed in 9.93s

git diff --check
exit 0
```

## Limitation

With `check_same_thread=True`, SQLite connections must be closed by their owning
thread. `SQLiteStore.close()` therefore closes the current thread's file-backed
connection; worker-thread connections are left for their owning worker/process
lifecycle rather than being closed unsafely from the UI thread. The test runner
also emits an unrelated Windows `PermissionError` while cleaning its shared
temporary `pytest-current` directory after successful test completion.
