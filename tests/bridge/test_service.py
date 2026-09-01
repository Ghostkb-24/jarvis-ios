from __future__ import annotations

from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import Barrier, Event, Lock

import pytest

from jarvis_assistant.bridge.auth import sign_confirmation, sign_request
from jarvis_assistant.bridge.device_store import DeviceStore
from jarvis_assistant.bridge.idempotency import IdempotencyConflict, IdempotencyLedger
from jarvis_assistant.bridge.pairing import PairedDevice, PairingSession, PairingSessionOwner
from jarvis_assistant.bridge.protocol import BridgeRequest, Risk, TaskConfirmation, TaskState
from jarvis_assistant.bridge.service import (
    BridgeAuthenticationError,
    BridgeAuthorizationError,
    BridgeService,
    BridgeValidationError,
)
from jarvis_assistant.storage import SQLiteStore
from jarvis_assistant.tools import default_registry

NOW = datetime(2026, 8, 28, 12, 0, tzinfo=UTC)
DEVICE_SECRET = b"0123456789abcdef0123456789abcdef"
OTHER_SECRET = b"abcdef0123456789abcdef0123456789"


class MemoryCredentialBackend:
    def __init__(self) -> None:
        self.passwords: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.passwords.get((service, username))

    def set_password(self, service: str, username: str, value: str) -> None:
        self.passwords[(service, username)] = value

    def delete_password(self, service: str, username: str) -> None:
        self.passwords.pop((service, username), None)


class RecordingVolume:
    def __init__(
        self,
        started: Event | None = None,
        release: Event | None = None,
    ) -> None:
        self.value = 20
        self.set_values: list[int] = []
        self._started = started
        self._release = release
        self._lock = Lock()

    def get_volume(self) -> int:
        return self.value

    def set_volume(self, percent: int) -> None:
        if self._started is not None:
            self._started.set()
        if self._release is not None:
            assert self._release.wait(timeout=2)
        with self._lock:
            self.value = percent
            self.set_values.append(percent)


def paired_device(
    device_id: str = "iphone-1",
    secret: bytes = DEVICE_SECRET,
) -> PairedDevice:
    return PairedDevice(
        device_id=device_id,
        display_name=device_id,
        created_at=NOW,
        last_seen_at=NOW,
        revoked=False,
        secret=secret,
    )


def bridge_request(
    *,
    request_id: str = "req-1",
    device_id: str = "iphone-1",
    issued_at: datetime = NOW,
    idempotency_key: str = "idem-1",
    kind: str = "tool",
    payload: dict | None = None,
) -> BridgeRequest:
    return BridgeRequest(
        version=1,
        request_id=request_id,
        device_id=device_id,
        issued_at=issued_at.isoformat().replace("+00:00", "Z"),
        idempotency_key=idempotency_key,
        kind=kind,
        payload=payload
        or {"tool": "set_volume", "arguments": {"percent": 35}},
    )


def make_service(
    database_path: Path,
    *,
    backend: MemoryCredentialBackend | None = None,
    volume: RecordingVolume | None = None,
    sent_messages: list[tuple[str, str]] | None = None,
    file_launcher: Callable[[str], object] | None = None,
    pairing_session: PairingSession | None = None,
    pairing_session_owner: PairingSessionOwner | None = None,
) -> tuple[BridgeService, SQLiteStore, MemoryCredentialBackend]:
    credential_backend = backend or MemoryCredentialBackend()
    store = SQLiteStore.open(database_path)
    devices = DeviceStore(store, credential_backend)
    if devices.get_device("iphone-1") is None:
        devices.save(paired_device())
    messages = sent_messages if sent_messages is not None else []
    registry = default_registry(
        volume=volume or RecordingVolume(),
        wechat_sender=lambda contact, message: not messages.append((contact, message)),
        application_activator=lambda _process: True,
        process_launcher=lambda _command: None,
        file_launcher=file_launcher or (lambda _path: None),
    )
    return (
        BridgeService(
            device_store=devices,
            ledger=IdempotencyLedger(store),
            registry=registry,
            pairing_session=pairing_session,
            pairing_session_owner=pairing_session_owner,
            now=lambda: NOW,
        ),
        store,
        credential_backend,
    )


def signed(request: BridgeRequest, secret: bytes = DEVICE_SECRET) -> str:
    return sign_request(secret, request)


def task_confirmation(
    request: BridgeRequest,
    *,
    task_id: str = "req-1",
    decision: str | None = None,
    decided_at: datetime = NOW,
) -> TaskConfirmation:
    return TaskConfirmation(
        version=1,
        request_id=request.request_id,
        task_id=task_id,
        decision=decision or ("approve" if request.kind == "confirm" else "decline"),
        decided_at=decided_at.isoformat().replace("+00:00", "Z"),
    )


def signed_confirmation(
    request: BridgeRequest,
    confirmation: TaskConfirmation,
    secret: bytes = DEVICE_SECRET,
) -> str:
    return sign_confirmation(secret, request, confirmation)


def test_pairing_claim_uses_the_exact_session_currently_shown_by_owner(tmp_path: Path) -> None:
    """Fails if the claim endpoint and QR display drift to different sessions."""
    owner = PairingSessionOwner(
        bridge_id="bridge-01",
        bridge_url="https://192.168.1.20:8443",
        certificate_sha256="ab" * 32,
        now=lambda: NOW,
    )
    service, store, _backend = make_service(
        tmp_path / "state.db",
        pairing_session_owner=owner,
    )
    shown = owner.session_for_display()

    try:
        device = service.claim_pairing(
            shown.session_id,
            "Alice's iPhone",
            shown.proof,
        )

        assert service.device_store.get_device(device.device_id) is not None
        assert owner.session_for_display().session_id != shown.session_id
    finally:
        store.close()


def test_submit_rejects_invalid_and_expired_signatures(tmp_path: Path) -> None:
    """Fails if unauthenticated or stale requests can reach dispatch."""
    service, _, _ = make_service(tmp_path / "state.db")
    valid = bridge_request()
    expired = bridge_request(issued_at=NOW - timedelta(seconds=301))

    with pytest.raises(BridgeAuthenticationError, match="signature"):
        service.submit(valid, "0" * 64)
    with pytest.raises(BridgeAuthenticationError, match="expired"):
        service.submit(expired, signed(expired))


def test_submit_rejects_unknown_revoked_and_missing_secret_devices(tmp_path: Path) -> None:
    """Fails if device metadata alone is enough to authenticate."""
    service, _, backend = make_service(tmp_path / "state.db")
    unknown = bridge_request(device_id="unknown")
    with pytest.raises(BridgeAuthenticationError, match="unknown"):
        service.submit(unknown, signed(unknown))

    service.device_store.revoke("iphone-1")
    revoked = bridge_request()
    with pytest.raises(BridgeAuthenticationError, match="revoked"):
        service.submit(revoked, signed(revoked))

    service.device_store.save(paired_device("iphone-2", OTHER_SECRET))
    backend.passwords.clear()
    missing = bridge_request(device_id="iphone-2")
    with pytest.raises(BridgeAuthenticationError, match="credential"):
        service.submit(missing, signed(missing, OTHER_SECRET))


def test_duplicate_low_risk_request_executes_once(tmp_path: Path) -> None:
    """Fails if sequential idempotent retries repeat a completed side effect."""
    volume = RecordingVolume()
    service, _, _ = make_service(tmp_path / "state.db", volume=volume)
    request = bridge_request()

    first = service.submit(request, signed(request))
    second = service.submit(request, signed(request))

    assert first == second
    assert first.state is TaskState.COMPLETED
    assert volume.set_values == [35]


def test_concurrent_duplicate_executes_once(tmp_path: Path) -> None:
    """Fails if two simultaneous reservations can both execute the handler."""
    handler_started = Event()
    release_handler = Event()
    volume = RecordingVolume(handler_started, release_handler)
    service, _, _ = make_service(tmp_path / "state.db", volume=volume)
    request = bridge_request()

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(service.submit, request, signed(request))
        assert handler_started.wait(timeout=2)
        second = executor.submit(service.submit, request, signed(request))
        second_state = second.result(timeout=2).state
        release_handler.set()
        first_state = first.result(timeout=2).state

    assert {first_state, second_state} == {TaskState.COMPLETED, TaskState.EXECUTING}
    assert volume.set_values == [35]
    assert service.get_task("req-1", "iphone-1").state is TaskState.COMPLETED


def test_duplicate_survives_service_restart(tmp_path: Path) -> None:
    """Fails if idempotency state exists only in process memory."""
    database_path = tmp_path / "state.db"
    backend = MemoryCredentialBackend()
    first_volume = RecordingVolume()
    first, first_store, _ = make_service(
        database_path,
        backend=backend,
        volume=first_volume,
    )
    request = bridge_request()
    expected = first.submit(request, signed(request))
    first_store.close()

    second_volume = RecordingVolume()
    restarted, _, _ = make_service(
        database_path,
        backend=backend,
        volume=second_volume,
    )
    actual = restarted.submit(request, signed(request))

    assert actual == expected
    assert first_volume.set_values == [35]
    assert second_volume.set_values == []


def test_restart_marks_interrupted_execution_result_unknown(tmp_path: Path) -> None:
    """Fails if a crash leaves a task perpetually executing and eligible for a retry."""
    database_path = tmp_path / "state.db"
    service, store, _ = make_service(database_path)
    request = bridge_request()
    record, _ = service._ledger.reserve(
        request,
        tool_name="set_volume",
        arguments={"percent": 35},
        state=TaskState.PREPARING,
        risk=Risk.LOW,
        response_payload={"tool": "set_volume", "arguments": {"percent": 35}},
    )
    service._ledger.begin_execution(record.request_id)
    store.close()

    restarted, _, _ = make_service(database_path)

    recovered = restarted.get_task(request.request_id, request.device_id)
    assert recovered.state is TaskState.RESULT_UNKNOWN


def test_restarted_sensitive_confirmation_never_executes_redacted_arguments(tmp_path: Path) -> None:
    """Fails if a restart lets a confirmation send a placeholder recipient or message."""
    database_path = tmp_path / "state.db"
    backend = MemoryCredentialBackend()
    sent: list[tuple[str, str]] = []
    first, store, _ = make_service(database_path, backend=backend, sent_messages=sent)
    request = bridge_request(
        payload={"tool": "send_wechat_message", "arguments": {"contact": "A", "message": "B"}}
    )
    first.submit(request, signed(request))
    store.close()
    restarted, _, _ = make_service(database_path, backend=backend, sent_messages=sent)
    confirmation = bridge_request(
        request_id="confirm-after-restart", idempotency_key="confirm-after-restart",
        kind="confirm", payload={"target_request_id": request.request_id},
    )

    response = restarted.confirm(
        request.request_id,
        confirmation,
        task_confirmation(confirmation, task_id=request.request_id),
        signed_confirmation(
            confirmation,
            task_confirmation(confirmation, task_id=request.request_id),
        ),
    )

    assert response.state is TaskState.RESULT_UNKNOWN
    assert sent == []


def test_idempotency_key_cannot_be_reused_for_different_request(tmp_path: Path) -> None:
    """Fails if one idempotency key aliases distinct signed operations."""
    service, _, _ = make_service(tmp_path / "state.db")
    first = bridge_request()
    conflict = bridge_request(
        request_id="req-2",
        payload={"tool": "set_volume", "arguments": {"percent": 80}},
    )
    service.submit(first, signed(first))

    with pytest.raises(IdempotencyConflict):
        service.submit(conflict, signed(conflict))


@pytest.mark.parametrize(
    ("tool", "arguments"),
    [
        ("clipboard", {"operation": "read"}),
        ("open_website", {"url": "https://example.com"}),
        ("delete_file", {"path": "secret.txt"}),
        ("make_payment", {"amount": 1}),
        ("enter_password", {"password": "secret"}),
        ("unknown", {}),
    ],
)
def test_bridge_rejects_unknown_and_forbidden_tools(
    tmp_path: Path,
    tool: str,
    arguments: dict,
) -> None:
    """Fails if registry growth silently expands the remote attack surface."""
    service, _, _ = make_service(tmp_path / "state.db")
    request = bridge_request(payload={"tool": tool, "arguments": arguments})

    with pytest.raises(BridgeValidationError, match="not allowed"):
        service.submit(request, signed(request))


@pytest.mark.parametrize(
    ("tool", "arguments"),
    [
        ("set_volume", {"percent": 30, "unexpected": True}),
        ("set_volume", {"percent": 101}),
        ("open_application", {"name": "   "}),
        ("search_files", {"query": "", "limit": 20}),
        ("open_file", {"path": ""}),
        ("send_wechat_message", {"contact": "Alice", "message": ""}),
    ],
)
def test_bridge_strictly_validates_remote_arguments(
    tmp_path: Path,
    tool: str,
    arguments: dict,
) -> None:
    """Fails if malformed or unexpected arguments cross the Bridge boundary."""
    service, _, _ = make_service(tmp_path / "state.db")
    request = bridge_request(payload={"tool": tool, "arguments": arguments})

    with pytest.raises(BridgeValidationError, match="arguments"):
        service.submit(request, signed(request))


@pytest.mark.parametrize(
    "arguments",
    [{"percent": "35"}, {"percent": True}, {"percent": 35.0}],
)
def test_bridge_rejects_coerced_volume_values(tmp_path: Path, arguments: dict) -> None:
    """Fails if Pydantic turns JSON strings, booleans, or floats into a volume integer."""
    service, _, _ = make_service(tmp_path / "state.db")
    request = bridge_request(payload={"tool": "set_volume", "arguments": arguments})

    with pytest.raises(BridgeValidationError, match="arguments"):
        service.submit(request, signed(request))


def test_wechat_contact_and_message_never_reach_bridge_task_sqlite(tmp_path: Path) -> None:
    """Fails if an awaiting WeChat task stores executable message plaintext."""
    service, store, _ = make_service(tmp_path / "state.db")
    request = bridge_request(
        payload={
            "tool": "send_wechat_message",
            "arguments": {"contact": "Alice secret", "message": "meet at eight"},
        }
    )

    service.submit(request, signed(request))
    rows = store.connection.execute(
        "select arguments_json, response_payload_json from bridge_tasks"
    ).fetchall()
    serialized = " ".join(" ".join(row) for row in rows)

    assert "Alice secret" not in serialized
    assert "meet at eight" not in serialized


def test_wechat_waits_for_owner_confirmation_and_replay_executes_once(tmp_path: Path) -> None:
    """Fails if a message sends before confirmation or a replay sends twice."""
    sent_messages: list[tuple[str, str]] = []
    service, _, _ = make_service(tmp_path / "state.db", sent_messages=sent_messages)
    request = bridge_request(
        payload={
            "tool": "send_wechat_message",
            "arguments": {"contact": "Alice", "message": "Meet at eight"},
        }
    )

    proposed = service.submit(request, signed(request))
    assert proposed.state is TaskState.AWAITING_CONFIRMATION
    assert proposed.payload["arguments"] == {
        "contact": "Alice",
        "message": "Meet at eight",
    }
    assert sent_messages == []

    confirmation = bridge_request(
        request_id="confirm-1",
        idempotency_key="confirm-idem-1",
        kind="confirm",
        payload={"target_request_id": request.request_id},
    )
    approval = task_confirmation(confirmation, task_id=request.request_id)
    signature = signed_confirmation(confirmation, approval)
    completed = service.confirm(request.request_id, confirmation, approval, signature)
    replayed = service.confirm(request.request_id, confirmation, approval, signature)

    assert completed.state is TaskState.COMPLETED
    assert replayed == completed
    assert sent_messages == [("Alice", "Meet at eight")]


def test_other_device_cannot_confirm_task(tmp_path: Path) -> None:
    """Fails if a valid paired device can approve another device's action."""
    service, _, _ = make_service(tmp_path / "state.db")
    service.device_store.save(paired_device("iphone-2", OTHER_SECRET))
    request = bridge_request(
        payload={
            "tool": "send_wechat_message",
            "arguments": {"contact": "Alice", "message": "Hello"},
        }
    )
    service.submit(request, signed(request))
    confirmation = bridge_request(
        request_id="confirm-2",
        device_id="iphone-2",
        idempotency_key="confirm-idem-2",
        kind="confirm",
        payload={"target_request_id": request.request_id},
    )

    with pytest.raises(BridgeAuthorizationError, match="owner"):
        service.confirm(
            request.request_id,
            confirmation,
            task_confirmation(confirmation, task_id=request.request_id),
            signed_confirmation(
                confirmation,
                task_confirmation(confirmation, task_id=request.request_id),
                OTHER_SECRET,
            ),
        )


def test_cancellation_is_terminal_and_never_executes(tmp_path: Path) -> None:
    """Fails if cancelled sensitive work can later be confirmed or executed."""
    sent_messages: list[tuple[str, str]] = []
    service, _, _ = make_service(tmp_path / "state.db", sent_messages=sent_messages)
    request = bridge_request(
        payload={
            "tool": "send_wechat_message",
            "arguments": {"contact": "Alice", "message": "Do not send"},
        }
    )
    service.submit(request, signed(request))
    cancellation = bridge_request(
        request_id="cancel-1",
        idempotency_key="cancel-idem-1",
        kind="cancel",
        payload={"target_request_id": request.request_id},
    )

    decline = task_confirmation(cancellation, task_id=request.request_id)
    signature = signed_confirmation(cancellation, decline)
    cancelled = service.confirm(request.request_id, cancellation, decline, signature)
    replayed = service.confirm(request.request_id, cancellation, decline, signature)

    assert cancelled.state is TaskState.CANCELLED
    assert replayed == cancelled
    assert sent_messages == []


def test_cross_application_tools_require_confirmation(tmp_path: Path, tmp_file: Path) -> None:
    """Fails if opening an application or file bypasses the approved confirmation policy."""
    service, _, _ = make_service(tmp_path / "state.db")
    tmp_file.write_text("data", encoding="utf-8")
    requests = (
        bridge_request(payload={"tool": "open_application", "arguments": {"name": "微信"}}),
        bridge_request(
            request_id="req-2",
            idempotency_key="idem-2",
            payload={"tool": "open_file", "arguments": {"path": str(tmp_file)}},
        ),
    )

    assert [service.submit(item, signed(item)).state for item in requests] == [
        TaskState.AWAITING_CONFIRMATION,
        TaskState.AWAITING_CONFIRMATION,
    ]


def test_bridge_never_opens_a_file_without_configured_allowed_roots(tmp_path: Path) -> None:
    """Fails if an unconfigured Bridge lets a confirmed request open any local file."""
    launched: list[str] = []
    path = tmp_path / "private.txt"
    path.write_text("not remotely accessible", encoding="utf-8")
    service, _, _ = make_service(
        tmp_path / "state.db",
        file_launcher=launched.append,
    )
    request = bridge_request(
        payload={"tool": "open_file", "arguments": {"path": str(path)}}
    )
    confirmation = bridge_request(
        request_id="confirm-open-file",
        idempotency_key="confirm-open-file-idem",
        kind="confirm",
        payload={"target_request_id": request.request_id},
    )

    assert service.submit(request, signed(request)).state is TaskState.AWAITING_CONFIRMATION
    approval = task_confirmation(confirmation, task_id=request.request_id)
    response = service.confirm(
        request.request_id,
        confirmation,
        approval,
        signed_confirmation(confirmation, approval),
    )

    assert response.state is TaskState.FAILED
    assert launched == []


def test_confirmation_rejects_legacy_request_only_signature(tmp_path: Path) -> None:
    """Fails if confirm/cancel can bypass signed decision and timestamp fields."""
    sent_messages: list[tuple[str, str]] = []
    service, _, _ = make_service(tmp_path / "state.db", sent_messages=sent_messages)
    request = bridge_request(
        payload={
            "tool": "send_wechat_message",
            "arguments": {"contact": "Alice", "message": "Meet at eight"},
        }
    )
    service.submit(request, signed(request))
    confirmation = bridge_request(
        request_id="confirm-legacy",
        idempotency_key="confirm-legacy-idem",
        kind="confirm",
        payload={"target_request_id": request.request_id},
    )
    approval = task_confirmation(confirmation, task_id=request.request_id)

    with pytest.raises(BridgeAuthenticationError, match="signature"):
        service.confirm(request.request_id, confirmation, approval, signed(confirmation))


def test_confirmation_rejects_mismatched_signed_decision(tmp_path: Path) -> None:
    """Fails if a signed decline can be replayed through the confirm path or vice versa."""
    sent_messages: list[tuple[str, str]] = []
    service, _, _ = make_service(tmp_path / "state.db", sent_messages=sent_messages)
    request = bridge_request(
        payload={
            "tool": "send_wechat_message",
            "arguments": {"contact": "Alice", "message": "Meet at eight"},
        }
    )
    service.submit(request, signed(request))
    confirmation = bridge_request(
        request_id="confirm-mismatch",
        idempotency_key="confirm-mismatch-idem",
        kind="confirm",
        payload={"target_request_id": request.request_id},
    )
    decline = task_confirmation(
        confirmation,
        task_id=request.request_id,
        decision="decline",
    )

    with pytest.raises(BridgeValidationError, match="decision"):
        service.confirm(
            request.request_id,
            confirmation,
            decline,
            signed_confirmation(confirmation, decline),
        )


@pytest.mark.asyncio
async def test_chat_request_dispatches_once_and_persists_response(tmp_path: Path) -> None:
    """Fails if authenticated chat is rejected or a duplicate invokes the model twice."""
    calls: list[str] = []

    async def chat(text: str) -> str:
        calls.append(text)
        return "本地回答"

    service, _, _ = make_service(tmp_path / "state.db")
    service._chat_dispatcher = chat
    request = bridge_request(
        kind="chat",
        payload={"text": "你好"},
    )

    first = await service.submit_async(request, signed(request))
    second = await service.submit_async(request, signed(request))

    assert first.state is TaskState.COMPLETED
    assert first.payload == {"summary": "本地回答"}
    assert second == first
    assert calls == ["你好"]


def test_bridge_audit_settings_and_revoke_writes_share_one_transaction_boundary(
    tmp_path: Path,
) -> None:
    """Concurrent bridge writes must not cause SQLite or transaction failures."""
    service, store, _ = make_service(tmp_path / "state.db")
    request = bridge_request()
    start = Barrier(4)

    def submit():
        return service.submit(request, signed(request))

    def audit() -> None:
        store.record_audit("set_volume", {"percent": 35}, True, "ok")

    def settings() -> None:
        store.save_settings(store.load_settings())

    def revoke() -> None:
        service.device_store.revoke("iphone-1")

    def run(operation: Callable[[], object]) -> object:
        start.wait(timeout=2)
        try:
            return operation()
        except Exception as error:
            return error

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = [
            executor.submit(run, operation)
            for operation in (submit, audit, settings, revoke)
        ]
        results = [future.result(timeout=2) for future in futures]

    errors = [result for result in results if isinstance(result, Exception)]
    assert all(isinstance(error, BridgeAuthenticationError) for error in errors)
    assert {str(error) for error in errors} <= {
        "revoked device",
        "device credential unavailable",
    }
    assert store.list_audit(1)[0].tool_name == "set_volume"
    assert service.device_store.get_device("iphone-1").revoked


@pytest.fixture
def tmp_file(tmp_path: Path) -> Path:
    return tmp_path / "allowed.txt"
