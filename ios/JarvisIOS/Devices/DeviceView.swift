import SwiftUI

struct DeviceView: View {
    let device: DeviceSnapshot

    var body: some View {
        NavigationStack {
            ZStack {
                JarvisTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        deviceCard
                        privacyCard
                    }
                    .padding(18)
                }
            }
            .navigationTitle("设备")
            .toolbarBackground(JarvisTheme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .accessibilityIdentifier("device.screen")
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(JarvisTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(JarvisTheme.emphasizedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.computerName)
                        .font(.headline)
                        .foregroundStyle(JarvisTheme.primaryText)
                    Text(device.connectionStatus)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(device.isConnected ? JarvisTheme.connected : JarvisTheme.error)
                        .accessibilityIdentifier("device.connection.status")
                }
            }

            Divider().overlay(Color.white.opacity(0.10))

            detailRow(
                symbol: "checkmark.shield.fill",
                title: "连接校验",
                value: device.isCertificatePinned ? "证书固定已验证" : "尚未验证",
                color: device.isCertificatePinned ? JarvisTheme.connected : JarvisTheme.warning
            )
            detailRow(
                symbol: "link.badge.plus",
                title: "配对状态",
                value: device.pairingStatus,
                color: device.isPaired ? JarvisTheme.connected : JarvisTheme.warning
            )
            detailRow(
                symbol: "cpu",
                title: "本地模型",
                value: device.modelStatus,
                color: device.isConnected ? JarvisTheme.accent : JarvisTheme.secondaryText
            )
            detailRow(
                symbol: "wifi",
                title: "网络",
                value: device.networkStatus,
                color: device.isConnected ? JarvisTheme.connected : JarvisTheme.warning
            )
        }
        .jarvisCard()
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(JarvisTheme.connected)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("隐私保护")
                    .font(.headline)
                    .foregroundStyle(JarvisTheme.primaryText)
                Text("配对凭据只保存在设备安全存储中，本页不会显示密钥、指纹或配对证明。")
                    .font(.subheadline)
                    .foregroundStyle(JarvisTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .jarvisCard()
    }

    private func detailRow(
        symbol: String,
        title: String,
        value: String,
        color: Color
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(JarvisTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(JarvisTheme.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
