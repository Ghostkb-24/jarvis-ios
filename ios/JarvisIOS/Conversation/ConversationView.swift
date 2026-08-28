import SwiftUI

struct ConversationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            JarvisTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    connectionHeader
                    voiceCore
                    conversation
                    computerStatus
                    composer

                    if model.isUITesting {
                        Text("测试客户端调用次数：\(model.testingClientCallCount)")
                            .font(.caption2)
                            .foregroundStyle(JarvisTheme.secondaryText)
                            .accessibilityIdentifier("testing.client-call-count")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .accessibilityIdentifier("conversation.screen")
    }

    private var connectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("JARVIS")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(JarvisTheme.primaryText)
                Text("你的私人智能助理")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.secondaryText)
            }

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: model.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(model.isConnected ? JarvisTheme.connected : JarvisTheme.error)
                    .accessibilityHidden(true)
                Text(model.isConnected ? "电脑已连接" : "电脑离线")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JarvisTheme.primaryText)
                    .accessibilityIdentifier("connection.status")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(JarvisTheme.elevatedSurface)
            .clipShape(Capsule())
        }
    }

    private var voiceCore: some View {
        VStack(spacing: 2) {
            VoiceOrb(phase: model.phase, action: model.toggleVoice)

            Text(model.phase.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(JarvisTheme.primaryText)
                .accessibilityIdentifier("phase.status")

            Text(model.phase.detail)
                .font(.subheadline)
                .foregroundStyle(JarvisTheme.secondaryText)
                .multilineTextAlignment(.center)

            if let notice = model.notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JarvisTheme.warning)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("对话")

            if model.messages.isEmpty {
                Text("开始一段新对话。跨应用操作会先让你确认。")
                    .font(.subheadline)
                    .foregroundStyle(JarvisTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.messages) { message in
                    messageBubble(message)
                }
            }
        }
        .jarvisCard()
        .accessibilityIdentifier("conversation.history")
    }

    private var computerStatus: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("电脑状态")

            statusRow(
                symbol: "desktopcomputer",
                label: model.isConnected ? "Windows 主机可用" : "Windows 主机离线",
                color: model.isConnected ? JarvisTheme.connected : JarvisTheme.error
            )
            statusRow(
                symbol: "cpu",
                label: model.device.modelStatus,
                color: model.isConnected ? JarvisTheme.accent : JarvisTheme.secondaryText
            )
            statusRow(
                symbol: "wifi",
                label: model.device.networkStatus,
                color: model.isConnected ? JarvisTheme.connected : JarvisTheme.warning
            )
        }
        .jarvisCard()
        .accessibilityIdentifier("computer.status")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("输入消息", text: $model.composerText, axis: .vertical)
                .lineLimit(1 ... 4)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(JarvisTheme.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(JarvisTheme.primaryText)
                .accessibilityIdentifier("composer.input")
                .onSubmit(model.submitComposer)

            Button(action: model.submitComposer) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 44, height: 44)
                    .background(JarvisTheme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送消息")
        }
        .accessibilityIdentifier("composer")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(JarvisTheme.primaryText)
    }

    private func messageBubble(_ message: ConversationMessage) -> some View {
        HStack {
            if message.author == .user { Spacer(minLength: 42) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(JarvisTheme.primaryText)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    message.author == .user
                        ? JarvisTheme.accent.opacity(0.24)
                        : JarvisTheme.emphasizedSurface
                )
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            if message.author == .jarvis { Spacer(minLength: 42) }
        }
        .frame(maxWidth: .infinity)
    }

    private func statusRow(symbol: String, label: String, color: Color) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(JarvisTheme.primaryText)
            Spacer()
        }
    }
}
