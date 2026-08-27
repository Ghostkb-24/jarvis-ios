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
    datas=[],
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter"],
    noarchive=False,
)
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
    disable_windowed_traceback=False,
)
