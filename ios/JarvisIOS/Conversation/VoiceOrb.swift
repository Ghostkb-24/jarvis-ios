import SwiftUI

struct VoiceOrb: View {
    let phase: AppModel.Phase
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(orbColor.opacity(0.16))
                    .frame(width: 148, height: 148)
                    .scaleEffect(isExpanded ? 1.08 : 0.90)
                    .opacity(isExpanded ? 0.32 : 0.72)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [orbColor.opacity(0.96), orbColor.opacity(0.34)],
                            center: .topLeading,
                            startRadius: 8,
                            endRadius: 72
                        )
                    )
                    .frame(width: 108, height: 108)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    }
                    .shadow(color: orbColor.opacity(0.28), radius: 22)

                Image(systemName: phase == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 160, height: 160)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phase == .listening ? "停止说话" : "开始说话")
        .accessibilityHint("切换 Jarvis 的语音输入状态")
        .onAppear(perform: updateAnimation)
        .onChange(of: phase) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private var shouldPulse: Bool {
        switch phase {
        case .listening, .transcribing, .thinking, .executing:
            true
        default:
            false
        }
    }

    private var orbColor: Color {
        switch phase {
        case .offline, .failed:
            JarvisTheme.error
        case .awaitingConfirmation, .resultUnknown:
            JarvisTheme.warning
        case .completed:
            JarvisTheme.connected
        default:
            JarvisTheme.accent
        }
    }

    private func updateAnimation() {
        guard shouldPulse, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = false
            }
            return
        }
        isExpanded = false
        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
            isExpanded = true
        }
    }
}
