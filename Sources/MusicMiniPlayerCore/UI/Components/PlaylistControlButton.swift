import SwiftUI

// Shared capsule-styled control button for the playlist page's Shuffle/Repeat
// row. Extracted from PlaylistView (TODOS.md Code Quality: 按钮重复) — the two
// buttons differed only in their icon content and enabled-state source; the
// capsule chrome (padding, background, glass texture, press style) was
// duplicated verbatim.
struct PlaylistControlButton<Icon: View>: View {
    let action: () -> Void
    let isEnabled: Bool
    let label: String
    let themeColor: Color
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? themeColor : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isEnabled ? themeColor.opacity(0.20) : .clear)
            )
            .modifier(GlassButtonTexture(shape: Capsule()))
            .contentShape(Capsule())
        }
        .buttonStyle(CapsulePressStyle())
    }
}
