import sqlite3
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, get_ident

from jarvis_assistant.domain import Settings
from jarvis_assistant.storage import CredentialStore, SQLiteStore


def test_settings_round_trip_without_secrets(tmp_path) -> None:
    store = SQLiteStore.open(tmp_path / "state.db")
    wanted = Settings(ollama_model="qwen2.5:3b", always_on_top=True)

    store.save_settings(wanted)

    assert store.load_settings() == wanted
    columns = store.connection.execute("pragma table_info(settings)").fetchall()
    assert "openai_api_key" not in {row[1] for row in columns}
    store.close()


def test_audit_redacts_user_profile_path(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("USERPROFILE", r"C:\Users\Alice")
    store = SQLiteStore.open(tmp_path / "state.db")

    store.record_audit(
        "open_file",
        {"path": r"C:\Users\Alice\secret.txt"},
        True,
        "opened",
    )

    event = store.list_audit(1)[0]
    assert "%USERPROFILE%" in event.arguments_summary
    assert "Alice" not in event.arguments_summary
    store.close()


def test_file_store_isolates_connections_for_concurrent_settings_and_audit_work(tmp_path) -> None:
    store = SQLiteStore.open(tmp_path / "state.db")
    barrier = Barrier(3)

    def bridge_settings_worker(index: int) -> tuple[int, int, int, str]:
        barrier.wait()
        connection = store.connection
        store.save_settings(Settings(ollama_model=f"bridge-{index}"))
        return (
            get_ident(),
            id(connection),
            connection.execute("pragma busy_timeout").fetchone()[0],
            connection.execute("pragma journal_mode").fetchone()[0],
        )

    def device_audit_worker(index: int) -> tuple[int, int, int, str]:
        barrier.wait()
        connection = store.connection
        store.record_audit("device_store", {"device": index}, True, "saved")
        return (
            get_ident(),
            id(connection),
            connection.execute("pragma busy_timeout").fetchone()[0],
            connection.execute("pragma journal_mode").fetchone()[0],
        )

    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = [
            executor.submit(bridge_settings_worker, 1),
            executor.submit(device_audit_worker, 2),
            executor.submit(device_audit_worker, 3),
        ]
        worker_connections = [future.result() for future in futures]

    assert len({thread_id for thread_id, _, _, _ in worker_connections}) == 3
    assert len({connection_id for _, connection_id, _, _ in worker_connections}) == 3
    connection_settings = {
        (busy_timeout, journal_mode)
        for _, _, busy_timeout, journal_mode in worker_connections
    }
    assert connection_settings == {(5000, "wal")}
    assert {event.tool_name for event in store.list_audit()} == {"device_store"}
    store.close()


def test_injected_connection_api_remains_available_for_memory_tests() -> None:
    connection = sqlite3.connect(":memory:")
    store = SQLiteStore(connection)

    assert store.connection is connection
    assert connection.row_factory is sqlite3.Row
    store.close()


def test_store_exposes_shared_lock_for_bridge_components() -> None:
    connection = sqlite3.connect(":memory:")
    store = SQLiteStore(connection)

    assert store.lock is store._lock  # noqa: SLF001
    store.close()


def test_open_migrates_paired_devices_schema(tmp_path) -> None:
    database_path = tmp_path / "state.db"
    legacy = sqlite3.connect(database_path)
    legacy.execute("pragma user_version = 1")
    legacy.close()

    store = SQLiteStore.open(database_path)

    columns = {
        row[1]: (row[2], row[3], row[4], row[5])
        for row in store.connection.execute("pragma table_info(paired_devices)")
    }
    assert columns == {
        "device_id": ("TEXT", 0, None, 1),
        "display_name": ("TEXT", 1, None, 0),
        "created_at": ("TEXT", 1, None, 0),
        "last_seen_at": ("TEXT", 1, None, 0),
        "revoked": ("INTEGER", 1, "0", 0),
    }
    assert store.connection.execute("pragma user_version").fetchone()[0] == 2
    store.close()


class MemoryKeyring:
    def __init__(self) -> None:
        self.values: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.values.get((service, username))

    def set_password(self, service: str, username: str, value: str) -> None:
        self.values[(service, username)] = value

    def delete_password(self, service: str, username: str) -> None:
        self.values.pop((service, username), None)


def test_credential_store_uses_keyring_without_exposing_key() -> None:
    backend = MemoryKeyring()
    credentials = CredentialStore(backend)

    credentials.set_openai_key("sk-private")

    assert credentials.get_openai_key() == "sk-private"
    assert "sk-private" not in repr(credentials)
