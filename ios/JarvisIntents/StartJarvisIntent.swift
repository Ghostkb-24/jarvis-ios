import AppIntents
import Foundation

enum JarvisDestination: String, AppEnum {
    case listening

    static let typeDisplayRepresentation = TypeDisplayRepresentation("Jarvis 页面")
    static let caseDisplayRepresentations: [JarvisDestination: DisplayRepresentation] = [
        .listening: DisplayRepresentation(title: "语音对话"),
    ]
}

struct StartJarvisIntent: OpenIntent {
    static let title: LocalizedStringResource = "启动 Jarvis"
    static let description = IntentDescription("打开 Jarvis 的语音对话入口，不会自动录音。")
    static let listeningURL = URL(string: "jarvis://listen")

    @Parameter(title: "入口")
    var target: JarvisDestination

    init() {
        target = .listening
    }

    init(target: JarvisDestination) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        ListeningEntryStore.requestListeningEntry()
        return .result()
    }
}

enum ListeningEntryStore {
    static let suiteName = "group.com.jarvisassistant.shared"
    static let pendingKey = "jarvis.pending.listening-entry.v1"

    static func requestListeningEntry() {
        UserDefaults(suiteName: suiteName)?.set(true, forKey: pendingKey)
    }

    static func consumeListeningEntry() -> Bool {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        let isPending = defaults.bool(forKey: pendingKey)
        if isPending {
            defaults.removeObject(forKey: pendingKey)
        }
        return isPending
    }
}
