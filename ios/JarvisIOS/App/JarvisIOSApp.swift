import SwiftUI

@main
struct JarvisIOSApp: App {
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel.launchConfigured())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(model: model)
                .preferredColorScheme(.dark)
                .tint(JarvisTheme.accent)
        }
    }
}
private struct RootTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            ConversationView(model: model)
                .tabItem {
                    Label("对话", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(AppTab.conversation)

            TaskListView(tasks: model.tasks)
                .tabItem {
                    Label("任务", systemImage: "checklist")
                }
                .tag(AppTab.tasks)

            DeviceView(device: model.device)
                .tabItem {
                    Label("设备", systemImage: "desktopcomputer")
                }
                .tag(AppTab.devices)
        }
        .background(JarvisTheme.background.ignoresSafeArea())
        .sheet(item: confirmationBinding) { preview in
            ActionPreviewSheet(
                preview: preview,
                onCancel: { model.cancelPreview(preview) },
                onAllow: { model.allow(preview) }
            )
            .interactiveDismissDisabled()
        }
    }

    private var confirmationBinding: Binding<ActionPreview?> {
        Binding(
            get: { model.pendingAction },
            set: { value in
                guard value == nil, let preview = model.pendingAction else { return }
                model.cancelPreview(preview)
            }
        )
    }
}
