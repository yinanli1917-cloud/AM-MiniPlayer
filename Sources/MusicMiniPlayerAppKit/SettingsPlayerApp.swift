/**
 * [INPUT]: Depends on MusicMiniPlayerCore's PlayerAppIdentity / PlayerAppIconProvider
 *          (the source-driven identity of the music app) and L10n.
 * [OUTPUT]: Exports the `playerApp` SwiftUI environment value, `PlayerAppIconView`
 *           (the real app icon, or the identity's SF Symbol when it is not
 *           installed) and `L10n.localized(_:player:)` (product-name copy).
 * [POS]: The one place the settings window learns WHICH music app it is for. No
 *        view or string in Settings names "Apple Music" / "Music" directly any
 *        more: a future edition that plays through NetEase Cloud Music or QQ
 *        Music changes the identity and the icons and copy follow.
 */

import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - Environment
// ──────────────────────────────────────────────

private struct PlayerAppKey: EnvironmentKey {
    static let defaultValue = PlayerAppIdentity.appleMusic
}

extension EnvironmentValues {
    /// The music app this window is configuring (default Apple Music).
    var playerApp: PlayerAppIdentity {
        get { self[PlayerAppKey.self] }
        set { self[PlayerAppKey.self] = newValue }
    }
}

// ──────────────────────────────────────────────
// MARK: - Icon
// ──────────────────────────────────────────────

/// The player app's icon at `size` pt, as installed on this Mac; its SF Symbol (secondary
/// tint, like a native settings glyph) when the app is not installed.
struct PlayerAppIconView: View {
    let identity: PlayerAppIdentity
    var size: CGFloat = 20

    var body: some View {
        let icon = PlayerAppIconProvider.shared.icon(for: identity, size: size)
        Group {
            if icon.isFallbackSymbol {
                Image(systemName: identity.fallbackSymbolName)
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// ──────────────────────────────────────────────
// MARK: - Copy
// ──────────────────────────────────────────────

extension L10n {
    /// `localized(key)` with `{player}` replaced by the product name ("Apple Music") and
    /// `{app}` by the application's own name ("Music") — the two ways copy names the player.
    static func localized(_ key: String, player: PlayerAppIdentity) -> String {
        localized(key)
            .replacingOccurrences(of: "{player}", with: player.displayName)
            .replacingOccurrences(of: "{app}", with: player.applicationName)
    }
}
