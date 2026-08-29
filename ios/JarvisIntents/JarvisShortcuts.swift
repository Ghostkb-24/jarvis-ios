import AppIntents

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartJarvisIntent(),
            phrases: [
                "启动 \(.applicationName)",
                "开始与 \(.applicationName) 对话",
            ],
            shortTitle: "启动 Jarvis",
            systemImageName: "waveform.circle.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .navy
    }
}
