# Windows Desktop Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows 11 desktop assistant with a transparent PySide6 interface, Ollama-first model routing, optional OpenAI fallback, push-to-talk voice input, and six security-controlled Windows tools.

**Architecture:** A PySide6 UI submits requests to an orchestrator that talks to model-provider adapters and can only invoke typed tools through a risk policy. SQLite persists non-secret state and audit records, while Windows Credential Manager stores the OpenAI key. Audio, models, tools, security, storage, and UI communicate through focused interfaces so each unit can be tested independently.

**Tech Stack:** Python 3.12, PySide6, Pydantic 2, httpx, keyring, SQLite, sounddevice, faster-whisper, pyttsx3, pynput, pytest, pytest-qt, pytest-asyncio, Ruff, PyInstaller.

**Spec:** `docs/superpowers/specs/2026-08-27-windows-desktop-assistant-design.md`

## Global Constraints

- Target Windows 11 and Python 3.12.
- Use Ollama model `qwen2.5:3b` as the default provider.
- Store the OpenAI key only in Windows Credential Manager through `keyring`.
- Never execute model-generated PowerShell, shell, or Python strings.
- Only registered tools with Pydantic-validated arguments may execute.
- Low-risk tools may execute automatically; medium-risk tools require explicit confirmation; forbidden actions cannot be registered.
- Do not send file contents, screenshots, clipboard contents, credentials, or raw personal paths to OpenAI.
- Use Chinese interface copy.
- Do not persist recorded audio.

---

### Task 1: Project Skeleton and Domain Contracts

**Files:**
- Create: `pyproject.toml`
- Create: `src/jarvis_assistant/__init__.py`
- Create: `src/jarvis_assistant/domain.py`
- Create: `tests/test_domain.py`

**Interfaces:**
- Produces: `RiskLevel`, `ActionStatus`, `ToolProposal`, `ToolResult`, `AssistantReply`, and `Settings`.
- Consumes: nothing.

- [ ] **Step 1: Write failing domain-contract tests**

```python
from pydantic import ValidationError
from jarvis_assistant.domain import RiskLevel, ToolProposal


def test_tool_proposal_rejects_blank_tool_name() -> None:
    try:
        ToolProposal(tool_name=" ", arguments={})
    except ValidationError:
        return
    raise AssertionError("blank tool name must fail validation")


def test_risk_levels_have_explicit_order() -> None:
    assert RiskLevel.LOW.value == 10
    assert RiskLevel.MEDIUM.value == 20
    assert RiskLevel.FORBIDDEN.value == 90
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `py -3.12 -m pytest tests/test_domain.py -v`

Expected: collection fails because `jarvis_assistant.domain` does not exist.

- [ ] **Step 3: Add packaging metadata and minimal contracts**

Create a `src`-layout package. Define `RiskLevel(IntEnum)`, `ActionStatus(StrEnum)`, and strict Pydantic models. Validate `ToolProposal.tool_name` with `min_length=1` and whitespace stripping. `ToolResult` contains `ok: bool`, `code: str`, `message: str`, and `data: dict[str, object]`. `AssistantReply` contains display text, optional spoken text, optional proposal, and provider name. `Settings` contains Ollama URL/model, OpenAI model, allowed search roots, UI preferences, and audio device names.

The dependency groups in `pyproject.toml` must include runtime dependencies and a `dev` extra with pytest, pytest-qt, pytest-asyncio, and Ruff.

- [ ] **Step 4: Run tests and lint**

Run: `py -3.12 -m pytest tests/test_domain.py -v`

Expected: 2 passed.

Run: `py -3.12 -m ruff check src tests`

Expected: no findings.

- [ ] **Step 5: Commit**

```powershell
git add pyproject.toml src/jarvis_assistant tests/test_domain.py
git commit -m "build: scaffold assistant domain"
```

---

### Task 2: Settings, Credential, and Audit Persistence

**Files:**
- Create: `src/jarvis_assistant/storage.py`
- Create: `tests/test_storage.py`

**Interfaces:**
- Consumes: `Settings`, `ToolProposal`, and `ToolResult` from `domain.py`.
- Produces: `SQLiteStore.open(path)`, `load_settings()`, `save_settings(settings)`, `record_audit(...)`, `list_audit(limit)`, `CredentialStore.get_openai_key()`, and `set_openai_key(value)`.

- [ ] **Step 1: Write failing persistence tests**

```python
from jarvis_assistant.domain import Settings
from jarvis_assistant.storage import SQLiteStore


def test_settings_round_trip_without_secrets(tmp_path) -> None:
    store = SQLiteStore.open(tmp_path / "state.db")
    wanted = Settings(ollama_model="qwen2.5:3b", always_on_top=True)
    store.save_settings(wanted)
    assert store.load_settings() == wanted
    columns = store.connection.execute("pragma table_info(settings)").fetchall()
    assert "openai_api_key" not in {row[1] for row in columns}


def test_audit_redacts_user_profile_path(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("USERPROFILE", r"C:\\Users\\Alice")
    store = SQLiteStore.open(tmp_path / "state.db")
    store.record_audit("open_file", {"path": r"C:\\Users\\Alice\\secret.txt"}, True, "opened")
    event = store.list_audit(1)[0]
    assert "%USERPROFILE%" in event.arguments_summary
    assert "Alice" not in event.arguments_summary
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/test_storage.py -v`

Expected: failure because `storage.py` does not exist.

- [ ] **Step 3: Implement SQLite migrations, redaction, and keyring wrapper**

Use schema version 1 with `settings`, `conversations`, and `audit_events` tables. Serialize settings as JSON excluding unset values. Redact `%USERPROFILE%`, values whose key contains `key`, `token`, `secret`, or `password`, and strings matching `sk-...`. Implement `CredentialStore` with service name `jarvis-desktop-assistant` and username `openai-api-key`.

- [ ] **Step 4: Verify GREEN and close resources**

Run: `py -3.12 -m pytest tests/test_storage.py -v`

Expected: all tests pass with no resource warnings.

- [ ] **Step 5: Commit**

```powershell
git add src/jarvis_assistant/storage.py tests/test_storage.py
git commit -m "feat: persist settings and audit events"
```

---

### Task 3: Typed Windows Tool Registry

**Files:**
- Create: `src/jarvis_assistant/tools.py`
- Create: `tests/test_tools.py`

**Interfaces:**
- Produces: `ToolSpec`, `ToolRegistry.register(spec)`, `schema_catalog()`, and `execute(proposal)`.
- Produces tools named `open_application`, `open_website`, `search_files`, `open_file`, `clipboard`, and `set_volume`.

- [ ] **Step 1: Write failing registry and validation tests**

```python
import pytest
from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.tools import ToolRegistry, default_registry


def test_registry_rejects_unknown_tool() -> None:
    registry = ToolRegistry()
    with pytest.raises(KeyError):
        registry.execute(ToolProposal(tool_name="run_shell", arguments={}))


def test_open_website_rejects_non_http_scheme() -> None:
    result = default_registry().execute(
        ToolProposal(tool_name="open_website", arguments={"url": "file:///C:/Windows/win.ini"})
    )
    assert not result.ok
    assert result.code == "invalid_arguments"
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/test_tools.py -v`

Expected: failure because `tools.py` does not exist.

- [ ] **Step 3: Implement schemas and tools**

Use one Pydantic input model per tool. Resolve application names only through a fixed registry containing Notepad, Calculator, Explorer, Settings, and the default browser. Validate URLs as HTTP/HTTPS. Restrict file search to configured roots and cap results at 20. Open files with `os.startfile` only after `Path.is_file()`. Use Qt clipboard through an injected adapter. Use a Windows audio adapter with `get_volume()` and `set_volume(percent)` so tests can substitute an in-memory adapter. Return `ToolResult` for operational failures instead of exposing exceptions.

- [ ] **Step 4: Add behavior tests with temporary files and injected adapters**

Test search-root escape rejection, result caps, file-not-found behavior, clipboard read/write, volume range validation, and safe application lookup. Do not launch real applications in the unit suite.

- [ ] **Step 5: Run GREEN**

Run: `py -3.12 -m pytest tests/test_tools.py -v`

Expected: all tool tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/jarvis_assistant/tools.py tests/test_tools.py
git commit -m "feat: add typed Windows tool registry"
```

---

### Task 4: Security Policy and Confirmation State

**Files:**
- Create: `src/jarvis_assistant/security.py`
- Create: `tests/test_security.py`

**Interfaces:**
- Consumes: tool specifications and `ToolProposal`.
- Produces: `DecisionKind(AUTO_EXECUTE, REQUIRE_CONFIRMATION, REJECT)`, `SecurityDecision`, and `SecurityPolicy.evaluate(proposal)`.

- [ ] **Step 1: Write failing policy tests**

```python
from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.security import DecisionKind, SecurityPolicy
from jarvis_assistant.tools import default_registry


def test_clipboard_write_requires_confirmation() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(
        ToolProposal(tool_name="clipboard", arguments={"operation": "write", "text": "hello"})
    )
    assert decision.kind is DecisionKind.REQUIRE_CONFIRMATION


def test_unregistered_tool_is_rejected() -> None:
    policy = SecurityPolicy(default_registry())
    decision = policy.evaluate(ToolProposal(tool_name="delete_file", arguments={"path": "x"}))
    assert decision.kind is DecisionKind.REJECT
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/test_security.py -v`

Expected: failure because `security.py` does not exist.

- [ ] **Step 3: Implement explicit decisions**

Map registered tools to low or medium risk. Treat clipboard reads as low and writes as medium. Reject unknown tools and invalid arguments. Create a Chinese confirmation summary from already validated arguments; abbreviate user-profile paths and never include clipboard content in the summary.

- [ ] **Step 4: Verify GREEN**

Run: `py -3.12 -m pytest tests/test_security.py -v`

Expected: all policy tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src/jarvis_assistant/security.py tests/test_security.py
git commit -m "feat: enforce tool risk policy"
```

---

### Task 5: Ollama/OpenAI Providers and Structured Parsing

**Files:**
- Create: `src/jarvis_assistant/models.py`
- Create: `tests/test_models.py`

**Interfaces:**
- Produces: async `ModelProvider.respond(request: ModelRequest) -> ModelResponse`.
- Produces: `OllamaProvider`, `OpenAIProvider`, `parse_model_response(text)`, and `ProviderRouter.choose(...)`.

- [ ] **Step 1: Write failing parser and routing tests**

```python
from jarvis_assistant.models import ProviderRouter, parse_model_response


def test_parser_accepts_allowlisted_tool_envelope() -> None:
    parsed = parse_model_response('{"type":"tool","tool_name":"open_application","arguments":{"name":"notepad"}}')
    assert parsed.proposal.tool_name == "open_application"


def test_router_uses_local_provider_first() -> None:
    router = ProviderRouter(openai_available=True)
    assert router.initial_provider() == "ollama"
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/test_models.py -v`

Expected: failure because `models.py` does not exist.

- [ ] **Step 3: Implement providers and strict envelopes**

Call Ollama at `/api/chat` with `format: "json"`, temperature 0, the tool schema catalog, and a prompt requiring exactly one envelope: `{"type":"answer","text":"...","confidence":0.0}` or `{"type":"tool","tool_name":"...","arguments":{},"confidence":0.0}`. Use OpenAI Responses API with structured output and send only the user request plus tool names/descriptions/schemas. Mark fallback eligible for transport failures, invalid envelopes, or confidence below `0.55`; never automatically send extra local context.

- [ ] **Step 4: Add async HTTP tests with `httpx.MockTransport`**

Cover success, timeout, malformed JSON, missing key, low confidence, and redaction of local context from the OpenAI request.

- [ ] **Step 5: Verify GREEN**

Run: `py -3.12 -m pytest tests/test_models.py -v`

Expected: all provider tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/jarvis_assistant/models.py tests/test_models.py
git commit -m "feat: route Ollama and OpenAI responses"
```

---

### Task 6: Request Orchestrator

**Files:**
- Create: `src/jarvis_assistant/orchestrator.py`
- Create: `tests/test_orchestrator.py`

**Interfaces:**
- Consumes: provider router, security policy, tool registry, and audit store.
- Produces: async `submit(text) -> OrchestratorEvent`, `confirm(action_id)`, `cancel(action_id)`, and an event stream for UI state changes.

- [ ] **Step 1: Write failing end-to-end state tests**

```python
import pytest
from jarvis_assistant.orchestrator import EventKind


@pytest.mark.asyncio
async def test_medium_risk_action_waits_for_confirmation(orchestrator_with_clipboard_write) -> None:
    events = await orchestrator_with_clipboard_write.submit("把 hello 放到剪贴板")
    assert events[-1].kind is EventKind.CONFIRMATION_REQUIRED
    assert orchestrator_with_clipboard_write.fake_clipboard.value == ""


@pytest.mark.asyncio
async def test_invalid_tool_never_executes(orchestrator_with_invalid_model) -> None:
    events = await orchestrator_with_invalid_model.submit("删除文件")
    assert events[-1].kind is EventKind.REJECTED
    assert orchestrator_with_invalid_model.executed_tools == []
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/test_orchestrator.py -v`

Expected: failure because `orchestrator.py` does not exist.

- [ ] **Step 3: Implement the state machine**

Use states `IDLE`, `THINKING_LOCAL`, `FALLBACK_AVAILABLE`, `THINKING_CLOUD`, `AWAITING_CONFIRMATION`, `EXECUTING`, `COMPLETED`, `FAILED`, and `CANCELLED`. Keep pending proposals in memory under UUID action IDs. A confirm call revalidates the proposal before execution. A cancel call removes it. Record every executed or rejected proposal with a redacted summary.

- [ ] **Step 4: Test automatic low-risk execution, explicit cloud fallback, retry, confirmation, cancellation, audit records, and exception conversion**

Use deterministic in-memory providers and adapters. Assert on real orchestrator events and adapter state rather than call-count-only mocks.

- [ ] **Step 5: Verify GREEN**

Run: `py -3.12 -m pytest tests/test_orchestrator.py -v`

Expected: all orchestrator tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/jarvis_assistant/orchestrator.py tests/test_orchestrator.py
git commit -m "feat: orchestrate secure assistant actions"
```

---

### Task 7: Push-to-Talk Audio Services

**Files:**
- Create: `src/jarvis_assistant/audio.py`
- Create: `tests/test_audio.py`

**Interfaces:**
- Produces: `AudioRecorder.start()`, `stop() -> AudioBuffer`, `Transcriber.transcribe(buffer) -> str`, and `Speaker.say(text)`.

- [ ] **Step 1: Write failing lifecycle tests**

```python
from jarvis_assistant.audio import AudioRecorder


def test_recorder_does_not_persist_audio(fake_audio_backend, tmp_path) -> None:
    recorder = AudioRecorder(fake_audio_backend)
    recorder.start()
    buffer = recorder.stop()
    assert buffer.samples
    assert list(tmp_path.iterdir()) == []
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/test_audio.py -v`

Expected: failure because `audio.py` does not exist.

- [ ] **Step 3: Implement memory-only recording and local speech**

Record 16 kHz mono float audio through `sounddevice` into memory. Transcribe with `faster-whisper`, defaulting to a configurable small multilingual model and Chinese language hint. Speak with Windows SAPI through `pyttsx3`, queueing only one utterance at a time. Raise typed errors for missing devices, empty audio, and model load failure. Never write WAV files.

- [ ] **Step 4: Test adapters and cancellation**

Use fake sample streams and fake transcription/speech engines. Verify empty recording, double start, stop-before-start, and speaker interruption behavior.

- [ ] **Step 5: Verify GREEN**

Run: `py -3.12 -m pytest tests/test_audio.py -v`

Expected: all audio tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/jarvis_assistant/audio.py tests/test_audio.py
git commit -m "feat: add push-to-talk audio services"
```

---

### Task 8: Transparent PySide6 Desktop UI

**Files:**
- Create: `src/jarvis_assistant/ui/__init__.py`
- Create: `src/jarvis_assistant/ui/theme.py`
- Create: `src/jarvis_assistant/ui/sidebar.py`
- Create: `src/jarvis_assistant/ui/console.py`
- Create: `src/jarvis_assistant/ui/capsule.py`
- Create: `src/jarvis_assistant/ui/settings.py`
- Create: `tests/ui/test_windows.py`

**Interfaces:**
- Consumes: orchestrator events, settings store, credentials, recorder, transcriber, and speaker.
- Produces: signals `request_submitted(str)`, `confirmation_answered(str, bool)`, `recording_requested(bool)`, and settings changes.

- [ ] **Step 1: Write failing pytest-qt widget tests**

```python
from PySide6.QtCore import Qt
from jarvis_assistant.ui.console import TaskConsole


def test_console_is_compact_translucent_and_hidden_by_default(qtbot) -> None:
    console = TaskConsole()
    qtbot.addWidget(console)
    assert console.width() <= 420
    assert not console.isVisible()
    assert console.testAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)


def test_confirmation_emits_action_id(qtbot) -> None:
    console = TaskConsole()
    qtbot.addWidget(console)
    console.show_confirmation("action-1", "写入剪贴板")
    with qtbot.waitSignal(console.confirmation_answered) as signal:
        qtbot.mouseClick(console.allow_button, Qt.MouseButton.LeftButton)
    assert signal.args == ["action-1", True]
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/ui/test_windows.py -v`

Expected: failure because the UI package does not exist.

- [ ] **Step 3: Implement approved surfaces**

Create frameless translucent widgets with a shared black `rgba` stylesheet and white text. Place the sidebar upper-left, compact console upper-right at no more than 420 logical pixels wide, and capsule centered above the taskbar. Add drag handling, always-on-top, click-through, state labels, Chinese controls, and confirmation buttons. Hide the console and capsule when idle. Do not perform model or tool work on the GUI thread.

- [ ] **Step 4: Test visibility, signals, dragging boundaries, settings updates, and Chinese text**

Use offscreen Qt in CI. Test widget state and emitted signals rather than screenshots. Add a manual visual checklist for opacity and placement.

- [ ] **Step 5: Verify GREEN**

Run: `$env:QT_QPA_PLATFORM='offscreen'; py -3.12 -m pytest tests/ui/test_windows.py -v`

Expected: all UI tests pass.

- [ ] **Step 6: Commit**

```powershell
git add src/jarvis_assistant/ui tests/ui
git commit -m "feat: build transparent desktop interface"
```

---

### Task 9: Application Composition, Tray, and Global Shortcut

**Files:**
- Create: `src/jarvis_assistant/app.py`
- Create: `src/jarvis_assistant/__main__.py`
- Create: `tests/test_app.py`

**Interfaces:**
- Consumes all completed services.
- Produces: `build_application(data_dir=None) -> ApplicationRuntime` and CLI command `jarvis-assistant`.

- [ ] **Step 1: Write failing composition tests**

```python
from jarvis_assistant.app import build_application


def test_runtime_registers_expected_tray_actions(qtbot, tmp_path) -> None:
    runtime = build_application(data_dir=tmp_path, test_mode=True)
    labels = [action.text() for action in runtime.tray.contextMenu().actions()]
    assert labels == ["打开控制台", "开始说话", "暂停助手", "设置", "退出"]
    runtime.shutdown()
```

- [ ] **Step 2: Verify RED**

Run: `$env:QT_QPA_PLATFORM='offscreen'; py -3.12 -m pytest tests/test_app.py -v`

Expected: failure because `app.py` does not exist.

- [ ] **Step 3: Compose services and lifecycle**

Build dependencies in one composition root. Move model/audio work to worker threads. Register `Ctrl+Alt+Space` through `pynput`, route it to push-to-talk, and handle registration failure without crashing. Implement tray actions, pause mode, settings opening, clean shutdown, database close, audio stop, speech stop, and shortcut unregistration. Use `%LOCALAPPDATA%/JarvisDesktopAssistant` as the production data directory.

- [ ] **Step 4: Test tray actions, pause behavior, duplicate shortcut failure, worker result delivery, and shutdown cleanup**

Use injected fake hotkey and service factories. Assert that no pending action executes after shutdown.

- [ ] **Step 5: Verify GREEN and launch manually**

Run: `$env:QT_QPA_PLATFORM='offscreen'; py -3.12 -m pytest tests/test_app.py -v`

Expected: all application tests pass.

Run: `py -3.12 -m jarvis_assistant`

Expected: tray icon appears, sidebar appears upper-left, console opens upper-right, and the process exits from the tray menu.

- [ ] **Step 6: Commit**

```powershell
git add src/jarvis_assistant/app.py src/jarvis_assistant/__main__.py tests/test_app.py
git commit -m "feat: compose desktop assistant runtime"
```

---

### Task 10: Packaging, Documentation, and Full Verification

**Files:**
- Create: `jarvis-assistant.spec`
- Create: `README.md`
- Create: `scripts/smoke_test.ps1`
- Create: `.gitignore`
- Modify: `pyproject.toml`

**Interfaces:**
- Produces: reproducible development setup, Windows executable build, and reversible smoke test.

- [ ] **Step 1: Write the smoke-test contract before the script**

Document in `README.md` that the smoke test must save and restore clipboard and volume, use only a temporary directory, open only Notepad and `https://example.com`, and print one PASS/FAIL line per check.

- [ ] **Step 2: Implement `scripts/smoke_test.ps1` with guaranteed restoration**

Use `try/finally`. Create a uniquely named directory under `$env:TEMP`, seed one test text file, run the application in smoke mode, verify the six tools, restore clipboard and original volume in `finally`, and remove only the resolved unique temporary directory after confirming it remains under `$env:TEMP`.

- [ ] **Step 3: Add PyInstaller build and user documentation**

Document Ollama startup, local model selection, optional key setup, shortcut behavior, tool risks, privacy rules, troubleshooting, tests, and packaging. Configure a windowed PyInstaller build that bundles UI resources but does not bundle Ollama models or OpenAI credentials.

- [ ] **Step 4: Run complete verification**

Run: `py -3.12 -m pytest -v`

Expected: all tests pass.

Run: `py -3.12 -m ruff check src tests`

Expected: no findings.

Run: `py -3.12 -m PyInstaller --clean jarvis-assistant.spec`

Expected: `dist/JarvisDesktopAssistant/JarvisDesktopAssistant.exe` exists.

Run: `powershell -ExecutionPolicy Bypass -File scripts/smoke_test.ps1`

Expected: every line reports PASS and the final line is `SMOKE TEST PASSED`; clipboard and volume match their original values.

- [ ] **Step 5: Commit**

```powershell
git add .gitignore README.md jarvis-assistant.spec scripts/smoke_test.ps1 pyproject.toml
git commit -m "docs: package and verify desktop assistant"
```
