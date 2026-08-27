from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PySide6.QtWidgets import QApplication

from jarvis_assistant.app import QtClipboardAdapter
from jarvis_assistant.domain import ToolProposal
from jarvis_assistant.tools import WindowsVolumeAdapter, default_registry


@dataclass(frozen=True)
class SmokeResult:
    name: str
    ok: bool
    message: str


class MemoryClipboard:
    def __init__(self) -> None:
        self.value = "original"

    def read(self) -> str:
        return self.value

    def write(self, text: str) -> None:
        self.value = text


class MemoryVolume:
    def __init__(self) -> None:
        self.value = 40

    def get_volume(self) -> int:
        return self.value

    def set_volume(self, percent: int) -> None:
        self.value = percent


def run_smoke(temp_root: str | Path, *, live: bool) -> list[SmokeResult]:
    root = Path(temp_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="jarvis-smoke-", dir=root)).resolve()
    if not work.is_relative_to(root):
        raise RuntimeError("temporary smoke directory escaped its root")

    clipboard = QtClipboardAdapter() if live else MemoryClipboard()
    volume = WindowsVolumeAdapter() if live else MemoryVolume()
    original_clipboard = clipboard.read()
    original_volume = volume.get_volume()
    launches: list[Any] = []

    def process_launcher(command: Any) -> Any:
        if live:
            return subprocess.Popen(list(command), shell=False)
        launches.append(command)
        return command

    def browser_opener(url: str) -> bool:
        if live:
            return webbrowser.open(url)
        launches.append(url)
        return True

    def file_launcher(path: str) -> bool:
        launches.append(path)
        return True

    try:
        test_file = work / "jarvis-smoke-report.txt"
        test_file.write_text("Jarvis smoke test", encoding="utf-8")
        registry = default_registry(
            allowed_search_roots=[work],
            clipboard=clipboard,
            volume=volume,
            process_launcher=process_launcher,
            browser_opener=browser_opener,
            file_launcher=file_launcher,
        )
        proposals = [
            ToolProposal(tool_name="open_application", arguments={"name": "notepad"}),
            ToolProposal(
                tool_name="open_website",
                arguments={"url": "https://example.com"},
            ),
            ToolProposal(
                tool_name="search_files",
                arguments={"query": "smoke-report", "root": str(work)},
            ),
            ToolProposal(tool_name="open_file", arguments={"path": str(test_file)}),
            ToolProposal(
                tool_name="clipboard",
                arguments={"operation": "write", "text": "jarvis-smoke"},
            ),
            ToolProposal(tool_name="set_volume", arguments={"percent": original_volume}),
        ]
        results = []
        for proposal in proposals:
            result = registry.execute(proposal)
            results.append(SmokeResult(proposal.tool_name, result.ok, result.message))
        return results
    finally:
        clipboard.write(original_clipboard)
        volume.set_volume(original_volume)
        if work.is_relative_to(root):
            shutil.rmtree(work)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Jarvis desktop assistant smoke test")
    parser.add_argument("--temp-root", required=True)
    parser.add_argument("--live", action="store_true")
    options = parser.parse_args(argv)
    _app = QApplication.instance() or QApplication([])
    results = run_smoke(options.temp_root, live=options.live)
    for result in results:
        label = "PASS" if result.ok else "FAIL"
        print(f"{label} {result.name}: {result.message}")
    if all(result.ok for result in results):
        print("SMOKE TEST PASSED")
        return 0
    print("SMOKE TEST FAILED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
