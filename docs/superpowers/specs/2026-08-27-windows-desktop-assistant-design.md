# Windows Desktop Assistant Design

## Objective

Build a Windows 11 desktop assistant that accepts Chinese text and push-to-talk voice input, uses Ollama locally by default, can fall back to OpenAI when explicitly configured, and executes a small allowlist of Windows actions through a confirmation-aware security layer.

The first release is a complete Windows MVP. Android and iPhone integration are separate future projects.

## Product Scope

### Included

- Python and PySide6 desktop application.
- System tray integration and global `Ctrl+Alt+Space` shortcut.
- Chinese text input and push-to-talk voice input.
- Ollama local inference using the installed `qwen2.5:3b` model by default.
- Optional OpenAI fallback when an API key is configured.
- Structured tool selection rather than arbitrary command generation.
- Risk classification, confirmation UI, argument validation, and audit logging.
- Six initial tools: open application, open website, search files, open file, read/write clipboard, and adjust system volume.
- SQLite persistence for non-secret settings, conversation metadata, window placement, and audit events.
- Windows Credential Manager storage for the OpenAI API key.

### Excluded

- Continuous wake-word listening.
- Automatic file deletion.
- Sending email or messages.
- Password, payment, or financial actions.
- Installation of software.
- Arbitrary PowerShell, shell, or Python execution.
- Phone control or a phone client.
- Autonomous visual clicking based on screenshots.
- Long-term personality memory.

## User Interface

The interface uses a restrained, transparent dark design with white primary text and muted gray-white secondary text.

### Compact Sidebar

- A small frameless surface positioned at the upper-left of the desktop.
- Shows the active model, latest short result, and an expand action.
- Remains visible by default and can be disabled in settings.
- Can be dragged, pinned on top, or made mouse-transparent.

### Task Console

- A compact frameless surface positioned at the upper-right of the desktop.
- Uses a semi-transparent black background, white text, and minimal controls.
- Hidden when idle by default.
- Opens when the user expands the sidebar, selects the tray action, or must approve an operation.
- Shows conversation, model routing, pending action details, confirmation controls, and errors.
- Can be dragged, pinned on top, or made mouse-transparent.

### Voice Capsule

- A small capsule centered above the taskbar.
- Hidden while idle.
- Appears during recording, transcription, model processing, and action execution.
- Shows the current phase and the `Esc` cancellation hint.

### Tray and Keyboard

- The tray menu contains Open Console, Start Talking, Pause Assistant, Settings, and Exit.
- `Ctrl+Alt+Space` starts recording; pressing it again or pressing `Esc` stops or cancels.
- Window positions and visibility preferences persist between launches.

## Architecture

### UI Layer

PySide6 owns the sidebar, console, capsule, settings dialog, tray icon, and confirmation prompts. The UI never directly performs Windows actions.

### Audio Layer

The audio layer records only after explicit push-to-talk activation, detects the end of an utterance, transcribes Chinese speech, and plays short spoken responses. It exposes stable interfaces so local and cloud speech implementations can change independently of the UI.

### Model Layer

The model layer provides a common interface for Ollama and OpenAI. Ollama is the default provider. OpenAI is optional and unavailable until the user configures a key in Windows Credential Manager.

### Orchestrator

The orchestrator owns request state, selects the model provider, validates model output, requests cloud fallback when appropriate, submits proposed tool calls to the security layer, executes approved actions, and produces the final response.

### Security Layer

The security layer maps every registered tool to a fixed risk level, validates typed arguments, rejects unregistered tools, redacts sensitive values, and determines whether an action can run automatically, needs confirmation, or is forbidden.

### Tool Layer

Every tool is a focused Python implementation with a typed input schema and a structured result. PowerShell may only be invoked through fixed internal command templates. Model-generated command strings are never executed.

### Storage Layer

SQLite stores non-secret configuration, window state, conversation metadata, and audit events. The OpenAI key is stored only in Windows Credential Manager. Logs contain parameter summaries rather than raw secrets or full private content.

## Request Flow

1. The user submits text or records speech with `Ctrl+Alt+Space`.
2. The audio layer converts speech to text when necessary.
3. The orchestrator sends the request to Ollama.
4. The local model returns either a normal response or a structured allowlisted tool proposal.
5. Invalid output, explicit low confidence, or a task classified as complex makes OpenAI fallback eligible.
6. If OpenAI is configured, the console discloses the fallback before the request is sent. If it is not configured, the assistant reports the limitation without executing an action.
7. A proposed tool call passes schema validation and risk classification.
8. Low-risk calls execute automatically. Medium-risk calls wait for confirmation. Forbidden calls are rejected.
9. The tool returns a structured result and the audit store records its redacted summary.
10. The assistant presents a concise text response and may speak a short result.

## Initial Tools and Risk Rules

| Tool | Scope | Default risk |
| --- | --- | --- |
| Open application | Launch an application resolved from an internal safe application registry | Low |
| Open website | Open an `http` or `https` URL after URL validation | Low |
| Search files | Search user-selected allowed roots without modifying files | Low |
| Open file | Open an existing file returned by the search layer or selected by the user | Low |
| Clipboard | Reading is low risk; writing replaces clipboard contents only after confirmation | Low / Medium |
| System volume | Set or adjust output volume within 0–100 percent | Low |

Deleting, moving, renaming, installing, messaging, credential entry, payments, and arbitrary commands are forbidden in this release.

## Cloud Privacy Rules

- File contents, screenshots, clipboard contents, credentials, and raw personal paths are not sent to OpenAI by default.
- The console visibly identifies a cloud fallback.
- The fallback payload contains only the user request and the minimum tool metadata required for routing.
- A future setting may permit additional context, but this release does not expose such permission.
- Secrets are redacted from UI errors and audit logs.

## Failure Handling

- Invalid model output is rejected and never treated as an executable command.
- Ollama unavailability produces a visible local-model error and offers OpenAI fallback only when configured.
- OpenAI failure returns control to the console without retrying destructive or side-effecting operations.
- Tool errors preserve a structured code and safe message for the UI.
- The console offers Retry, Use Cloud when eligible, and Cancel.
- Cancellation stops pending recording or model work and prevents a not-yet-started action from running.
- Application exit unregisters the global shortcut, closes audio input, and flushes the audit store.

## Persistence

- Persist window coordinates, always-on-top preference, click-through preference, active local model name, audio device selection, and non-secret feature settings.
- Do not persist recorded audio by default.
- Store conversation metadata and redacted audit events in SQLite.
- Use schema migrations so later releases can extend persisted state safely.

## Testing Strategy

### Unit Tests

- Provider routing and OpenAI fallback eligibility.
- Structured model-output parsing.
- Tool registry allowlisting.
- Argument validation.
- Risk classification and confirmation decisions.
- Secret and path redaction.
- Settings and audit persistence.

### Integration Tests

- Exercise the complete orchestrator flow with deterministic fake model providers.
- Verify that invalid or forbidden proposals never reach a tool implementation.
- Verify confirmation, cancellation, retry, and fallback transitions.

### Windows Smoke Tests

- Open Notepad through the application registry.
- Open a known test URL.
- Search for and open a temporary test file in an explicitly allowed temporary directory.
- Read and restore a test clipboard value.
- Exercise volume integration without leaving the original value changed.

### UI Tests

- Application startup and clean shutdown.
- Tray actions and window show/hide behavior.
- Confirmation and cancellation.
- Shortcut registration handling.
- Window placement and settings persistence.
- Chinese rendering, transparency, dragging, topmost mode, and click-through mode on Windows 11.

## Acceptance Criteria

- The application starts on Windows 11 and remains accessible from the system tray.
- Text requests work without an OpenAI key by using the installed Ollama service.
- Configuring an OpenAI key enables disclosed fallback without storing the key in SQLite or plaintext files.
- The six initial tools can only be invoked through validated structured calls.
- Medium-risk calls cannot execute without explicit confirmation.
- Forbidden and unregistered actions never execute.
- The approved upper-left sidebar, upper-right compact console, and taskbar-centered capsule match the transparent black-and-white design direction.
- Automated tests pass and the Windows smoke-test checklist completes without leaving modified clipboard or volume state.
