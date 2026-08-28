import SwiftUI

struct ActionPreviewSheet: View {
    let preview: ActionPreview
    let onCancel: () -> Void
    let onAllow: () -> Void

    var body: some View {
        ZStack {
            JarvisTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)

                    HStack(alignment: .top, spacing: 13) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(JarvisTheme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("发送前请确认")
                                .font(.title2.bold())
                                .foregroundStyle(JarvisTheme.primaryText)
                            Text("这是一次对外发送操作。只有你允许后，Jarvis 才会继续。")
                                .font(.subheadline)
                                .foregroundStyle(JarvisTheme.secondaryText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        previewLabel("收件人")
                        Text("收件人：\(preview.recipient)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(JarvisTheme.primaryText)
                            .textSelection(.enabled)

                        Divider().overlay(Color.white.opacity(0.10))

                        previewLabel("完整消息")
                        Text(preview.message)
                            .font(.body)
                            .foregroundStyle(JarvisTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .jarvisCard()

                    Text("请逐字核对。取消后不会联系电脑客户端，也不会发送消息。")
                        .font(.footnote)
                        .foregroundStyle(JarvisTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        Button(action: onAllow) {
                            Text("允许并发送")
                                .font(.headline)
                                .foregroundStyle(Color.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(JarvisTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("允许并发送")

                        Button(role: .cancel, action: onCancel) {
                            Text("取消操作")
                                .font(.headline)
                                .foregroundStyle(JarvisTheme.primaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(JarvisTheme.emphasizedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消操作")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .accessibilityIdentifier("confirmation.preview")
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private func previewLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(JarvisTheme.secondaryText)
            .textCase(.uppercase)
    }
}
