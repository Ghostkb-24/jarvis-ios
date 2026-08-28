from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from threading import RLock
from typing import Any

from jarvis_assistant.bridge.protocol import BridgeRequest, BridgeResponse, Risk, TaskState
from jarvis_assistant.storage import SQLiteStore


class IdempotencyConflict(ValueError):
    """Raised when a request identifier is reused for different signed content."""


@dataclass(frozen=True)
class TaskRecord:
    request_id: str
    idempotency_key: str
    device_id: str
    request_digest: str
    tool_name: str
    arguments: dict[str, Any]
    state: TaskState
    risk: Risk
    response_payload: dict[str, Any]
    result_summary: str

    def response(self) -> BridgeResponse:
        return BridgeResponse(
            version=1,
            request_id=self.request_id,
            state=self.state,
            risk=self.risk,
            payload=self.response_payload,
        )

class IdempotencyLedger:
    def __init__(self, store: SQLiteStore) -> None:
        self._store = store
        self._lock = RLock()
        with self._lock:
            self._store.connection.executescript(
                """
                create table if not exists bridge_tasks (
                    request_id text primary key,
                    idempotency_key text not null unique,
                    device_id text not null,
                    request_digest text not null,
                    tool_name text not null,
                    arguments_json text not null,
                    state text not null,
                    risk text not null,
                    response_payload_json text not null,
                    result_summary text not null default '',
                    created_at text not null,
                    updated_at text not null
                );
                """
            )
            self._store.connection.commit()

    def reserve(
        self,
        request: BridgeRequest,
        *,
        tool_name: str,
        arguments: dict[str, Any],
        state: TaskState,
        risk: Risk,
        response_payload: dict[str, Any],
    ) -> tuple[TaskRecord, bool]:
        digest = hashlib.sha256(request.canonical_bytes()).hexdigest()
        with self._lock:
            connection = self._store.connection
            connection.execute("begin immediate")
            try:
                row = connection.execute(
                    "select * from bridge_tasks where request_id = ? or idempotency_key = ?",
                    (request.request_id, request.idempotency_key),
                ).fetchone()
                if row is not None:
                    record = self._record(row)
                    if not self._matches(record, request, digest):
                        raise IdempotencyConflict(
                            "request ID or idempotency key was reused for different content"
                        )
                    connection.commit()
                    return record, False

                timestamp = datetime.now(UTC).isoformat()
                connection.execute(
                    "insert into bridge_tasks("
                    "request_id, idempotency_key, device_id, request_digest, tool_name, "
                    "arguments_json, state, risk, response_payload_json, result_summary, "
                    "created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?)",
                    (
                        request.request_id,
                        request.idempotency_key,
                        request.device_id,
                        digest,
                        tool_name,
                        self._dump(arguments),
                        state.value,
                        risk.value,
                        self._dump(response_payload),
                        timestamp,
                        timestamp,
                    ),
                )
                row = connection.execute(
                    "select * from bridge_tasks where request_id = ?",
                    (request.request_id,),
                ).fetchone()
                connection.commit()
                assert row is not None
                return self._record(row), True
            except Exception:
                connection.rollback()
                raise

    def get(self, request_id: str) -> TaskRecord | None:
        with self._lock:
            row = self._store.connection.execute(
                "select * from bridge_tasks where request_id = ?",
                (request_id,),
            ).fetchone()
            return self._record(row) if row is not None else None

    def begin_execution(self, request_id: str) -> tuple[TaskRecord, bool]:
        with self._lock:
            connection = self._store.connection
            connection.execute("begin immediate")
            try:
                row = connection.execute(
                    "select * from bridge_tasks where request_id = ?",
                    (request_id,),
                ).fetchone()
                if row is None:
                    raise KeyError(request_id)
                record = self._record(row)
                if record.state not in {
                    TaskState.PREPARING,
                    TaskState.AWAITING_CONFIRMATION,
                }:
                    connection.commit()
                    return record, False
                connection.execute(
                    "update bridge_tasks set state = ?, response_payload_json = ?, "
                    "updated_at = ? where request_id = ?",
                    (
                        TaskState.EXECUTING.value,
                        self._dump({"summary": "正在执行。"}),
                        datetime.now(UTC).isoformat(),
                        request_id,
                    ),
                )
                row = connection.execute(
                    "select * from bridge_tasks where request_id = ?",
                    (request_id,),
                ).fetchone()
                connection.commit()
                assert row is not None
                return self._record(row), True
            except Exception:
                connection.rollback()
                raise

    def finish(
        self,
        request_id: str,
        *,
        state: TaskState,
        response_payload: dict[str, Any],
        result_summary: str,
    ) -> TaskRecord:
        if state not in {
            TaskState.COMPLETED,
            TaskState.FAILED,
            TaskState.RESULT_UNKNOWN,
        }:
            raise ValueError("finish requires a terminal execution state")
        with self._lock:
            self._store.connection.execute(
                "update bridge_tasks set state = ?, response_payload_json = ?, "
                "result_summary = ?, updated_at = ? where request_id = ?",
                (
                    state.value,
                    self._dump(response_payload),
                    result_summary,
                    datetime.now(UTC).isoformat(),
                    request_id,
                ),
            )
            self._store.connection.commit()
            record = self.get(request_id)
            if record is None:
                raise KeyError(request_id)
            return record

    def cancel(self, request_id: str) -> TaskRecord:
        with self._lock:
            connection = self._store.connection
            connection.execute("begin immediate")
            try:
                row = connection.execute(
                    "select * from bridge_tasks where request_id = ?",
                    (request_id,),
                ).fetchone()
                if row is None:
                    raise KeyError(request_id)
                record = self._record(row)
                if record.state in {
                    TaskState.PREPARING,
                    TaskState.AWAITING_CONFIRMATION,
                }:
                    connection.execute(
                        "update bridge_tasks set state = ?, response_payload_json = ?, "
                        "result_summary = ?, updated_at = ? where request_id = ?",
                        (
                            TaskState.CANCELLED.value,
                            self._dump({"summary": "操作已取消。"}),
                            "操作已取消。",
                            datetime.now(UTC).isoformat(),
                            request_id,
                        ),
                    )
                    row = connection.execute(
                        "select * from bridge_tasks where request_id = ?",
                        (request_id,),
                    ).fetchone()
                    assert row is not None
                    record = self._record(row)
                connection.commit()
                return record
            except Exception:
                connection.rollback()
                raise

    @staticmethod
    def _matches(record: TaskRecord, request: BridgeRequest, digest: str) -> bool:
        return (
            record.request_id == request.request_id
            and record.idempotency_key == request.idempotency_key
            and record.device_id == request.device_id
            and record.request_digest == digest
        )

    @staticmethod
    def _dump(value: dict[str, Any]) -> str:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    @staticmethod
    def _record(row: Any) -> TaskRecord:
        return TaskRecord(
            request_id=row["request_id"],
            idempotency_key=row["idempotency_key"],
            device_id=row["device_id"],
            request_digest=row["request_digest"],
            tool_name=row["tool_name"],
            arguments=json.loads(row["arguments_json"]),
            state=TaskState(row["state"]),
            risk=Risk(row["risk"]),
            response_payload=json.loads(row["response_payload_json"]),
            result_summary=row["result_summary"],
        )
