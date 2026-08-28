import SwiftUI

enum JarvisTheme {
    static let background = Color.black
    static let elevatedSurface = Color.white.opacity(0.06)
    static let emphasizedSurface = Color.white.opacity(0.10)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.62, green: 0.66, blue: 0.72)
    static let accent = Color(red: 0.26, green: 0.80, blue: 0.92)
    static let connected = Color(red: 0.37, green: 0.84, blue: 0.62)
    static let warning = Color(red: 0.95, green: 0.67, blue: 0.31)
    static let error = Color(red: 0.95, green: 0.38, blue: 0.42)
    static let cornerRadius: CGFloat = 22
}
private struct JarvisCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(JarvisTheme.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: JarvisTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: JarvisTheme.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

extension View {
    func jarvisCard() -> some View {
        modifier(JarvisCard())
    }
}
