import SwiftUI
import WidgetKit

struct JarvisWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: JarvisWidgetSnapshot
}

struct JarvisWidgetSnapshot: Codable, Equatable, Sendable {
    let connectionStatus: String
    let modelStatus: String
    let updatedAt: Date

    static let offline = JarvisWidgetSnapshot(
        connectionStatus: "offline",
        modelStatus: "本地模型不可用",
        updatedAt: .distantPast
    )

    var isConnected: Bool {
        connectionStatus == "connected"
    }
}

struct JarvisWidgetSnapshotStore {
    static let suiteName = "group.com.jarvisassistant.shared"
    static let snapshotKey = "jarvis.widget.status.v1"

    func load() -> JarvisWidgetSnapshot {
        guard
            let data = UserDefaults(suiteName: Self.suiteName)?.data(
                forKey: Self.snapshotKey
            ),
            let snapshot = try? JSONDecoder().decode(
                JarvisWidgetSnapshot.self,
                from: data
            )
        else {
            return .offline
        }
        return snapshot
    }
}

struct JarvisWidgetProvider: TimelineProvider {
    private let store = JarvisWidgetSnapshotStore()

    func placeholder(in context: Context) -> JarvisWidgetEntry {
        JarvisWidgetEntry(
            date: Date(),
            snapshot: JarvisWidgetSnapshot(
                connectionStatus: "connected",
                modelStatus: "本地模型就绪",
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (JarvisWidgetEntry) -> Void
    ) {
        completion(JarvisWidgetEntry(date: Date(), snapshot: store.load()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<JarvisWidgetEntry>) -> Void
    ) {
        let entry = JarvisWidgetEntry(date: Date(), snapshot: store.load())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct JarvisWidgetEntryView: View {
    let entry: JarvisWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(entry.snapshot.isConnected ? "Jarvis · 电脑已连接" : "Jarvis · 电脑离线")
            case .accessoryCircular:
                Image(systemName: entry.snapshot.isConnected ? "waveform.circle.fill" : "wifi.slash")
                    .font(.title2)
                    .accessibilityLabel(
                        entry.snapshot.isConnected ? "Jarvis，电脑已连接" : "Jarvis，电脑离线"
                    )
            case .accessoryRectangular:
                accessoryStatus
            default:
                homeStatus
            }
        }
        .widgetURL(StartJarvisIntent.listeningURL)
        .containerBackground(for: .widget) {
            Color.black
        }
    }

    private var accessoryStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("JARVIS", systemImage: "waveform.circle.fill")
                .font(.headline)
            Text(entry.snapshot.isConnected ? "电脑已连接" : "电脑离线")
                .font(.caption)
            Text("轻点开始对话")
                .font(.caption2)
        }
    }

    private var homeStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                Text("JARVIS")
                    .font(.headline)
                Spacer()
            }

            Text(entry.snapshot.isConnected ? "电脑已连接" : "电脑离线")
                .font(.subheadline.weight(.semibold))
            Text(entry.snapshot.modelStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Label("开始对话", systemImage: "mic.fill")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.white)
        .padding(2)
    }
}

struct JarvisWidget: Widget {
    static let kind = "com.jarvisassistant.ios.widget.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: JarvisWidgetProvider()) { entry in
            JarvisWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Jarvis 对话")
        .description("查看电脑连接状态并打开 Jarvis 语音入口。")
        .supportedFamilies([
            .systemSmall,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

@main
struct JarvisWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        JarvisWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            JarvisControl()
        }
    }
}
