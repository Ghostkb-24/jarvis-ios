# -*- mode: python ; coding: utf-8 -*-

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_submodules


hiddenimports = []
for package in ("faster_whisper", "keyring.backends", "pynput", "pyttsx3.drivers"):
    hiddenimports += collect_submodules(package)

binaries = collect_dynamic_libs("ctranslate2") + collect_dynamic_libs("onnxruntime")

analysis = Analysis(
    ["src/jarvis_assistant/__main__.py"],
    pathex=["src"],
    binaries=binaries,
    datas=[("assets", "assets")],
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter"],
    noarchive=False,
)
# Qt 6 on Windows uses the ICU implementation shipped by the OS.  The Codex
# runtime also puts Poppler's incompatible unversioned ICU DLLs on PATH, which
# PyInstaller can accidentally collect and load ahead of System32.
blocked_runtime_dlls = {"icuuc.dll", "icudt78.dll"}
analysis.binaries = [
    entry for entry in analysis.binaries if entry[0].lower() not in blocked_runtime_dlls
]
pyz = PYZ(analysis.pure)
exe = EXE(
    pyz,
    analysis.scripts,
    analysis.binaries,
    analysis.datas,
    [],
    name="JarvisDesktopAssistant",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    icon="assets/jarvis-kobe.ico",
    disable_windowed_traceback=False,
)
