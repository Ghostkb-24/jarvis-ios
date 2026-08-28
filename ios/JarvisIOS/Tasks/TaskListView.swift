import SwiftUI

struct TaskListView: View {
    let tasks: [JarvisTaskSummary]

    var body: some View {
        NavigationStack {
            ZStack {
                JarvisTheme.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if tasks.isEmpty {
                            ContentUnavailableView(
                                "暂无任务",
                                systemImage: "checklist",
                                description: Text("Jarvis 的执行状态会显示在这里")
                            )
                            .foregroundStyle(JarvisTheme.secondaryText)
                            .padding(.top, 90)
                        } else {
                            ForEach(tasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("任务")
            .toolbarBackground(JarvisTheme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .accessibilityIdentifier("task.list")
    }

    private func taskRow(_ task: JarvisTaskSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: task.symbol)
                .font(.title2)
                .foregroundStyle(statusColor(task.status))
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(JarvisTheme.primaryText)
                Text(task.detail)
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.secondaryText)
            }

            Spacer()

            Text(task.status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(JarvisTheme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(statusColor(task.status).opacity(0.18))
                .clipShape(Capsule())
        }
        .jarvisCard()
        .accessibilityElement(children: .combine)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "已完成":
            JarvisTheme.connected
        case "等待确认":
            JarvisTheme.warning
        case "失败":
            JarvisTheme.error
        default:
            JarvisTheme.accent
        }
    }
}
