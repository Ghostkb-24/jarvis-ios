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
                            .foregroundStyle(preview.allowsApproval ? JarvisTheme.warning : JarvisTheme.error)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preview.title)
                                .font(.title2.bold())
                                .foregroundStyle(JarvisTheme.primaryText)
                            Text(preview.summary)
                                .font(.subheadline)
                                .foregroundStyle(JarvisTheme.secondaryText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        previewLabel("目标应用")
                        Text(preview.target)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(JarvisTheme.primaryText)

                        Divider().overlay(Color.white.opacity(0.10))

                        previewLabel("操作")
                        Text(preview.action)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(JarvisTheme.primaryText)

                        Divider().overlay(Color.white.opacity(0.10))

                        ForEach(preview.details) { detail in
                            previewLabel(detail.label)
                            Text("\(detail.label)：\(detail.value)")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(JarvisTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)

                            if detail.id != preview.details.last?.id {
                                Divider().overlay(Color.white.opacity(0.10))
                            }
                        }
                    }
                    .jarvisCard()

                    Text(
                        preview.allowsApproval
                            ? "请逐字核对。取消后不会联系电脑客户端，也不会发送消息。"
                            : "这类操作保持人工执行。Jarvis 不会绕过付款、删除文件或密码输入限制。"
                    )
                        .font(.footnote)
                        .foregroundStyle(JarvisTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        if preview.allowsApproval {
                            Button(action: onAllow) {
                                Text(preview.primaryButtonTitle)
                                    .font(.headline)
                                    .foregroundStyle(Color.black)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(JarvisTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preview.primaryButtonTitle)
                        }

                        Button(role: preview.allowsApproval ? .cancel : nil, action: onCancel) {
                            Text(preview.allowsApproval ? "取消操作" : "知道了")
                                .font(.headline)
                                .foregroundStyle(JarvisTheme.primaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(JarvisTheme.emphasizedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preview.allowsApproval ? "取消操作" : "知道了")
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
