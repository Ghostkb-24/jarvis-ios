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
