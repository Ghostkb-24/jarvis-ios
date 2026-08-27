# Jarvis Wake Word Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fully local always-on “你好，Jarvis” wake-word control using the Lian II microphone.

**Architecture:** A focused wake listener owns the keyword stream. ApplicationRuntime coordinates exclusive microphone ownership and resumes listening after command processing.

**Tech Stack:** Python 3.12, PySide6, sounddevice, sherpa-onnx, pytest

**Spec:** `docs/superpowers/specs/2026-08-27-jarvis-wake-word-design.md`

## Global Constraints

- Wake phrase is exactly “你好，Jarvis”.
- Audio remains local and is not persisted.
- Device is Lian II.
- Existing Ctrl+Alt+Space behavior remains available.

---

### Task 1: Wake listener

**Files:** Create `src/jarvis_assistant/wake_word.py`; create `tests/test_wake_word.py`.

**Interfaces:** Produces `WakeWordListener.start(callback)`, `stop()`, and `running`.

- [ ] Write tests for start, detection callback, stop, and backend failure.
- [ ] Run focused tests and verify RED.
- [ ] Implement the listener with injected backend boundaries.
- [ ] Run focused tests and verify GREEN.

### Task 2: Runtime state integration

**Files:** Modify `src/jarvis_assistant/app.py`; modify `tests/test_app.py`.

**Interfaces:** Consumes `WakeWordListener`; pauses it before formal recording and resumes after completion or error.

- [ ] Write tests for wake, microphone exclusion, pause, resume, and shutdown.
- [ ] Run focused tests and verify RED.
- [ ] Implement runtime coordination and tray toggle.
- [ ] Run focused tests and verify GREEN.

### Task 3: Packaging and verification

**Files:** Modify `pyproject.toml`; modify `jarvis-assistant.spec` only if model data must be bundled.

- [ ] Add the pinned runtime dependency and model asset configuration.
- [ ] Run the full test and lint suites.
- [ ] Build the EXE and launch it independently.
- [ ] Verify Lian II wake detection and command execution manually.
