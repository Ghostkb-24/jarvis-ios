from __future__ import annotations

import base64
from datetime import UTC, datetime
from pathlib import Path

from jarvis_assistant.bridge.device_store import DeviceStore
from jarvis_assistant.bridge.pairing import PairedDevice
from jarvis_assistant.storage import SQLiteStore


class MemoryCredentialBackend:
    def __init__(self) -> None:
        self.passwords: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.passwords.get((service, username))

    def set_password(self, service: str, username: str, value: str) -> None:
        self.passwords[(service, username)] = value

    def delete_password(self, service: str, username: str) -> None:
        self.passwords.pop((service, username), None)


CREATED_AT = datetime(2026, 8, 28, 12, 0, tzinfo=UTC)
DEVICE_SECRET = b"test-device-secret-that-must-not-enter-sqlite"


def make_device() -> PairedDevice:
    return PairedDevice(
        device_id="device-01",
        display_name="Alice's iPhone",
        created_at=CREATED_AT,
        last_seen_at=CREATED_AT,
        revoked=False,
        secret=DEVICE_SECRET,
    )


def test_save_and_get_device_metadata_and_secret(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    sqlite_store = SQLiteStore.open(tmp_path / "jarvis.db")
    store = DeviceStore(sqlite_store, backend)

    store.save(make_device())

    saved = store.get_device("device-01")
    assert saved is not None
    assert saved.device_id == "device-01"
    assert saved.display_name == "Alice's iPhone"
    assert saved.created_at == CREATED_AT
    assert saved.last_seen_at == CREATED_AT
    assert saved.revoked is False
    assert store.get_secret("device-01") == DEVICE_SECRET
    assert backend.passwords[("jarvis-bridge-device", "device-01")]


def test_device_metadata_and_credential_survive_store_reload(tmp_path: Path) -> None:
    database_path = tmp_path / "jarvis.db"
    backend = MemoryCredentialBackend()
    sqlite_store = SQLiteStore.open(database_path)
    DeviceStore(sqlite_store, backend).save(make_device())
    sqlite_store.close()

    reopened_sqlite = SQLiteStore.open(database_path)
    reopened = DeviceStore(reopened_sqlite, backend)

    assert reopened.get_device("device-01") is not None
    assert reopened.get_secret("device-01") == DEVICE_SECRET


def test_revoke_marks_device_and_deletes_credential(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    store = DeviceStore(SQLiteStore.open(tmp_path / "jarvis.db"), backend)
    store.save(make_device())

    store.revoke("device-01")

    device = store.get_device("device-01")
    assert device is not None
    assert device.revoked is True
    assert store.get_secret("device-01") is None
    assert ("jarvis-bridge-device", "device-01") not in backend.passwords


def test_revoke_is_idempotent_for_known_and_unknown_devices(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    store = DeviceStore(SQLiteStore.open(tmp_path / "jarvis.db"), backend)
    store.save(make_device())

    store.revoke("device-01")
    store.revoke("device-01")
    store.revoke("unknown-device")
    store.revoke("unknown-device")

    assert store.get_secret("device-01") is None
    assert store.get_device("unknown-device") is None


def test_get_secret_returns_none_when_credential_is_missing(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    store = DeviceStore(SQLiteStore.open(tmp_path / "jarvis.db"), backend)
    store.save(make_device())
    backend.passwords.clear()

    assert store.get_secret("device-01") is None
    assert store.get_secret("unknown-device") is None


def test_sqlite_never_contains_device_secret(tmp_path: Path) -> None:
    database_path = tmp_path / "jarvis.db"
    backend = MemoryCredentialBackend()
    sqlite_store = SQLiteStore.open(database_path)
    store = DeviceStore(sqlite_store, backend)

    store.save(make_device())

    rows = sqlite_store.connection.execute("select * from paired_devices").fetchall()
    serialized_rows = repr([dict(row) for row in rows])
    assert DEVICE_SECRET.decode() not in serialized_rows
    assert DEVICE_SECRET.hex() not in serialized_rows
    assert base64.urlsafe_b64encode(DEVICE_SECRET).decode() not in serialized_rows
    database_bytes = database_path.read_bytes()
    assert DEVICE_SECRET not in database_bytes
    assert DEVICE_SECRET.hex().encode() not in database_bytes
    assert base64.urlsafe_b64encode(DEVICE_SECRET) not in database_bytes
