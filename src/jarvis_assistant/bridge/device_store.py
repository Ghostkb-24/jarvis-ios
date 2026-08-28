from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from jarvis_assistant.bridge.pairing import PairedDevice
from jarvis_assistant.storage import SQLiteStore


class CredentialBackend(Protocol):
    def get_password(self, service: str, username: str) -> str | None: ...

    def set_password(self, service: str, username: str, value: str) -> None: ...

    def delete_password(self, service: str, username: str) -> None: ...


@dataclass(frozen=True)
class StoredDevice:
    device_id: str
    display_name: str
    created_at: datetime
    last_seen_at: datetime
    revoked: bool


class DeviceStore:
    CREDENTIAL_SERVICE = "jarvis-bridge-device"

    def __init__(self, store: SQLiteStore, credential_backend: CredentialBackend) -> None:
        self._store = store
        self._credentials = credential_backend

    def save(self, device: PairedDevice) -> None:
        if device.revoked:
            self._delete_credential_if_present(device.device_id)
        else:
            encoded_secret = base64.urlsafe_b64encode(device.secret).decode("ascii")
            self._credentials.set_password(
                self.CREDENTIAL_SERVICE,
                device.device_id,
                encoded_secret,
            )
        self._store.connection.execute(
            "insert into paired_devices(device_id, display_name, created_at, last_seen_at, "
            "revoked) values (?, ?, ?, ?, ?) "
            "on conflict(device_id) do update set display_name = excluded.display_name, "
            "created_at = excluded.created_at, last_seen_at = excluded.last_seen_at, "
            "revoked = excluded.revoked",
            (
                device.device_id,
                device.display_name,
                device.created_at.isoformat(),
                device.last_seen_at.isoformat(),
                int(device.revoked),
            ),
        )
        self._store.connection.commit()

    def get_device(self, device_id: str) -> StoredDevice | None:
        row = self._store.connection.execute(
            "select device_id, display_name, created_at, last_seen_at, revoked "
            "from paired_devices where device_id = ?",
            (device_id,),
        ).fetchone()
        if row is None:
            return None
        return StoredDevice(
            device_id=row["device_id"],
            display_name=row["display_name"],
            created_at=datetime.fromisoformat(row["created_at"]),
            last_seen_at=datetime.fromisoformat(row["last_seen_at"]),
            revoked=bool(row["revoked"]),
        )

    def get_secret(self, device_id: str) -> bytes | None:
        device = self.get_device(device_id)
        if device is None or device.revoked:
            return None
        encoded_secret = self._credentials.get_password(
            self.CREDENTIAL_SERVICE,
            device_id,
        )
        if not encoded_secret:
            return None
        try:
            secret = base64.b64decode(encoded_secret, altchars=b"-_", validate=True)
        except (ValueError, binascii.Error):
            return None
        return secret or None

    def revoke(self, device_id: str) -> None:
        self._store.connection.execute(
            "update paired_devices set revoked = 1 where device_id = ?",
            (device_id,),
        )
        self._store.connection.commit()
        self._delete_credential_if_present(device_id)

    def _delete_credential_if_present(self, device_id: str) -> None:
        if self._credentials.get_password(self.CREDENTIAL_SERVICE, device_id) is not None:
            self._credentials.delete_password(self.CREDENTIAL_SERVICE, device_id)
