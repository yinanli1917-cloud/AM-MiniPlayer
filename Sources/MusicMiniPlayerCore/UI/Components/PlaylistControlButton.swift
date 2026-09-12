import SwiftUI
import Foundation

/// Pure resolver for the Shuffle/Repeat toggle's two-stage animation, factored
/// out of the MiniPlayerView call site so the arm/reduceMotion decision is
/// testable without a live view. `.legacy055` preserves today's underdamped
/// rebound; `.critical` swaps the rebound spring for the critically-damped
/// tokens in `MicroInteractionFeel.Tokens` (no overshoot). Reduce Motion wins
/// regardless of arm, matching the existing `guard !reduceMotion else { return }`
/// short-circuit at the call site (both animations become nil/no-op).
enum ShuffleRepeatStyle {
    static func resolve(
        arm: MicroInteractionFeel.ShuffleRepeatMode,
        reduceMotion: Bool
    ) -> (trigger: Animation?, rebound: Animation?) {
        guard !reduceMotion else { return (nil, nil) }
        let trigger = Animation.spring(response: 0.12, dampingFraction: 0.9)
        switch arm {
        case .legacy055:
            return (trigger, .spring(response: 0.35, dampingFraction: 0.55))
        case .critical:
            return (
                trigger,
                .spring(
                    response: MicroInteractionFeel.Tokens.shuffleReboundResponse,
                    dampingFraction: MicroInteractionFeel.Tokens.shuffleReboundDamping
                )
            )
        }
    }

    /// Analytic peak-overshoot fraction of a unit-step second-order spring
    /// response, given damping ratio `dampingFraction` (response/frequency
    /// cancels out of the overshoot formula, so it is not a parameter).
    /// For ζ >= 1 (critically/over-damped) there is no overshoot.
    static func overshoot(response: Double, dampingFraction: Double) -> Double {
        let zeta = dampingFraction
        guard zeta < 1 else { return 0 }
        let numerator = -zeta * Double.pi
        let denominator = (1 - zeta * zeta).squareRoot()
        return exp(numerator / denominator)
    }
}

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
