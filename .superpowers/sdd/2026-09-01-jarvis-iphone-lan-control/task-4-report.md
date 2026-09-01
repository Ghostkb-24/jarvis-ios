Task 4 report

Status
- Implemented a minimal desktop LAN bridge adapter in `src/jarvis_assistant/lan_bridge.py`, switched `src/jarvis_assistant/app.py` to compose it, and added focused coverage in `tests/test_lan_bridge.py`.

Files changed
- `src/jarvis_assistant/lan_bridge.py`
- `src/jarvis_assistant/app.py`
- `tests/test_lan_bridge.py`

Verification
- `py -3.12 -m pytest tests/test_lan_bridge.py -q`

```text
......                                                                   [100%]
============================== warnings summary ===============================
G:\Lib\site-packages\fastapi\testclient.py:1
  G:\Lib\site-packages\fastapi\testclient.py:1: StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.
    from starlette.testclient import TestClient as TestClient  # noqa

-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
6 passed, 1 warning in 0.61s
Exception ignored in atexit callback: <function cleanup_numbered_dir at 0x000001E9DE211BC0>
Traceback (most recent call last):
  File "G:\Lib\site-packages\_pytest\pathlib.py", line 374, in cleanup_numbered_dir
    cleanup_dead_symlinks(root)
  File "G:\Lib\site-packages\_pytest\pathlib.py", line 359, in cleanup_dead_symlinks
    if not left_dir.resolve().exists():
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "G:\Lib\pathlib.py", line 860, in exists
    self.stat(follow_symlinks=follow_symlinks)
  File "G:\Lib\pathlib.py", line 840, in stat
    return os.stat(self, follow_symlinks=follow_symlinks)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
PermissionError: [WinError 5] 拒绝访问。: 'C:\\Users\\Administrator\\AppData\\Local\\Temp\\pytest-of-Administrator\\pytest-current'
```

- `py -3.12 -m ruff check src/jarvis_assistant/lan_bridge.py src/jarvis_assistant/app.py tests/test_lan_bridge.py`

```text
All checks passed!
```

Open concerns
- This is the requested minimum path. It provides local HTTPS composition, signed submit/confirm handling, pairing-challenge claim, websocket task updates, blocked-risk refusals, and disconnect cleanup, but it does not yet add broader orchestration/event-history behavior beyond the focused tests above.
- `pytest` completes successfully, but this Windows host emits an unrelated `_pytest.pathlib.cleanup_numbered_dir` atexit `PermissionError` against `pytest-current`; I left it unchanged and recorded the exact output above.
