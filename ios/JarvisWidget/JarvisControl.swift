import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct JarvisControl: ControlWidget {
    static let kind = "com.jarvisassistant.ios.control.listen"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(
                action: StartJarvisIntent(target: .listening)
            ) {
                Label("与 Jarvis 对话", systemImage: "waveform.circle.fill")
                    .controlWidgetActionHint("打开 Jarvis 语音入口")
            }
        }
        .displayName("Jarvis 对话")
        .description("打开语音入口；录音仍需你在 App 内明确开始。")
    }
}
