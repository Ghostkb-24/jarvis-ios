from pathlib import Path

PROJECT_YML = Path(__file__).parents[1] / "ios" / "project.yml"
APP_ENTRY = PROJECT_YML.parent / "JarvisIOS" / "App" / "JarvisIOSApp.swift"


def _jarvis_app_target() -> str:
    project = PROJECT_YML.read_text(encoding="utf-8")
    app_start = project.index("  JarvisIOS:\n")
    widget_start = project.index("  JarvisWidget:\n", app_start)
    return project[app_start:widget_start]


def test_jarvis_app_info_contains_scene_and_voice_privacy_configuration() -> None:
    app_target = _jarvis_app_target()

    assert "UIApplicationSceneManifest:" in app_target
    assert "UIApplicationSupportsMultipleScenes: false" in app_target
    assert "CFBundleURLTypes:" in app_target
    assert "CFBundleURLSchemes:" in app_target
    assert "- jarvis" in app_target
    assert "NSMicrophoneUsageDescription:" in app_target
    assert "NSSpeechRecognitionUsageDescription:" in app_target

    app_entry = APP_ENTRY.read_text(encoding="utf-8")
    assert "@Environment(\\.scenePhase)" in app_entry
    assert ".onChange(of: scenePhase)" in app_entry
    assert "model.appWillResignActive()" in app_entry
