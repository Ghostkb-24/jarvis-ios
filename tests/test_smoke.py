from jarvis_assistant.smoke import run_smoke


def test_dry_smoke_checks_all_tools_and_cleans_temp_directory(tmp_path) -> None:
    results = run_smoke(tmp_path, live=False)
    assert all(result.ok for result in results)
    assert {result.name for result in results} == {
        "open_application",
        "open_website",
        "search_files",
        "open_file",
        "clipboard",
        "set_volume",
    }
    assert list(tmp_path.iterdir()) == []
