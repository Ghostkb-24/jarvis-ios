import SwiftUI
import UIKit

struct SpeechPermissionView: View {
    let status: SpeechPermissionStatus

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("语音权限未开启", systemImage: "mic.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(JarvisTheme.primaryText)

            Text(permissionExplanation)
                .font(.caption)
                .foregroundStyle(JarvisTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("打开系统设置") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                openURL(settingsURL)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(JarvisTheme.accent)
            .accessibilityHint("在系统设置中允许麦克风和语音识别")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(JarvisTheme.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("speech.permission")
    }

    private var permissionExplanation: String {
        switch status {
        case .restricted:
            "此设备限制了麦克风或语音识别。Jarvis 不会在后台录音。"
        case .denied:
            "请允许麦克风和语音识别。权限只会在你点击开始说话后使用。"
        case .undetermined, .authorized:
            "权限只会在你明确开始语音输入后请求和使用。"
        }
    }
}
