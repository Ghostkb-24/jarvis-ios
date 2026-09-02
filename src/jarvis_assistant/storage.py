from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from threading import RLock, local
from typing import Any, Protocol

from pydantic import BaseModel, ConfigDict

from jarvis_assistant.domain import Settings


class AuditEvent(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: int
    created_at: str
    tool_name: str
    arguments_summary: str
    ok: bool
    result_summary: str


class SQLiteStore:
    def __init__(
        self,
        connection: sqlite3.Connection | None = None,
        *,
        database_path: Path | None = None,
    ) -> None:
        if (connection is None) == (database_path is None):
            raise ValueError("provide either a connection or a database path")
        self._lock = RLock()
        # Backward-compatible public alias used by bridge/device components.
        self.lock = self._lock
        self._provided_connection = connection
        self._database_path = database_path
        self._thread_local = local()
        if connection is not None:
            connection.row_factory = sqlite3.Row

    @classmethod
    def open(cls, path: str | Path) -> SQLiteStore:
        database_path = Path(path)
        database_path.parent.mkdir(parents=True, exist_ok=True)
        store = cls(database_path=database_path)
        store._migrate()
        return store

    @property
    def connection(self) -> sqlite3.Connection:
        with self._lock:
            if self._provided_connection is not None:
                return self._provided_connection
            connection = getattr(self._thread_local, "connection", None)
            if connection is None:
                connection = sqlite3.connect(self._database_path)
                connection.row_factory = sqlite3.Row
                connection.execute("pragma journal_mode = WAL")
                connection.execute("pragma busy_timeout = 5000")
                self._thread_local.connection = connection
            return connection

    def _migrate(self) -> None:
        with self._lock:
            self.connection.executescript(
                """
                create table if not exists settings (
                    id integer primary key check (id = 1),
                    payload text not null
                );
                create table if not exists conversations (
                    id integer primary key autoincrement,
                    created_at text not null,
                    role text not null,
                    content_summary text not null
                );
                create table if not exists audit_events (
                    id integer primary key autoincrement,
                    created_at text not null,
                    tool_name text not null,
                    arguments_summary text not null,
                    ok integer not null,
                    result_summary text not null
                );
                create table if not exists paired_devices (
                    device_id text primary key,
                    display_name text not null,
                    created_at text not null,
                    last_seen_at text not null,
                    revoked integer not null default 0 check (revoked in (0, 1))
                );
                pragma user_version = 2;
                """
            )
            self.connection.commit()

    def load_settings(self) -> Settings:
        with self._lock:
            row = self.connection.execute("select payload from settings where id = 1").fetchone()
        if row is None:
            return Settings()
        return Settings.model_validate_json(row["payload"])

    def save_settings(self, settings: Settings) -> None:
        payload = settings.model_dump_json(exclude_unset=True)
        with self._lock:
            self.connection.execute(
                "insert into settings(id, payload) values(1, ?) "
                "on conflict(id) do update set payload = excluded.payload",
                (payload,),
            )
            self.connection.commit()

    def record_audit(
        self,
        tool_name: str,
        arguments: dict[str, Any],
        ok: bool,
        result_summary: str,
    ) -> None:
        safe_arguments = redact_value(arguments)
        safe_result = str(redact_value(result_summary))
        with self._lock:
            self.connection.execute(
                "insert into audit_events(created_at, tool_name, arguments_summary, ok, "
                "result_summary) values (?, ?, ?, ?, ?)",
                (
                    datetime.now(UTC).isoformat(),
                    tool_name,
                    json.dumps(safe_arguments, ensure_ascii=False, sort_keys=True),
                    int(ok),
                    safe_result,
                ),
            )
            self.connection.commit()

    def list_audit(self, limit: int = 100) -> list[AuditEvent]:
        with self._lock:
            rows = self.connection.execute(
                "select id, created_at, tool_name, arguments_summary, ok, result_summary "
                "from audit_events order by id desc limit ?",
                (max(0, limit),),
            ).fetchall()
        return [AuditEvent(**dict(row)) for row in rows]

    def close(self) -> None:
        with self._lock:
            if self._provided_connection is not None:
                self._provided_connection.close()
                return
            connection = getattr(self._thread_local, "connection", None)
            if connection is not None:
                connection.close()
                del self._thread_local.connection


_SECRET_KEY_PARTS = ("key", "token", "secret", "password")
_OPENAI_KEY = re.compile(r"sk-[A-Za-z0-9_-]+")


def redact_value(value: Any, key: str = "") -> Any:
    if any(part in key.casefold() for part in _SECRET_KEY_PARTS):
        return "[REDACTED]"
    if isinstance(value, dict):
        return {
            str(item_key): redact_value(item_value, str(item_key))
            for item_key, item_value in value.items()
        }
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, Path):
        value = str(value)
    if isinstance(value, str):
        profile = os.environ.get("USERPROFILE")
        if profile:
            value = value.replace(profile, "%USERPROFILE%")
        return _OPENAI_KEY.sub("[REDACTED]", value)
    return value


class KeyringBackend(Protocol):
    def get_password(self, service: str, username: str) -> str | None: ...

    def set_password(self, service: str, username: str, value: str) -> None: ...

    def delete_password(self, service: str, username: str) -> None: ...


class CredentialStore:
    SERVICE = "jarvis-desktop-assistant"
    USERNAME = "openai-api-key"

    def __init__(self, backend: KeyringBackend | None = None) -> None:
        if backend is None:
            import keyring

            backend = keyring
        self._backend = backend

    def get_openai_key(self) -> str | None:
        return self._backend.get_password(self.SERVICE, self.USERNAME)

    def set_openai_key(self, value: str | None) -> None:
        if value:
            self._backend.set_password(self.SERVICE, self.USERNAME, value)
        else:
            self._backend.delete_password(self.SERVICE, self.USERNAME)

    def __repr__(self) -> str:
        return "CredentialStore(service='jarvis-desktop-assistant')"
