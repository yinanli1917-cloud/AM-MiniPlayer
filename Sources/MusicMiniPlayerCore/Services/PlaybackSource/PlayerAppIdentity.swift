import AppKit
import Foundation

// =============================================================================
// [INPUT]: AppKit's NSWorkspace (public LaunchServices lookups) + the
//          PlaybackSource family (each source names the app it plays through)
// [OUTPUT]: PlayerAppIdentity (bundle id + product/app name + fallback symbol),
//           PlayerAppIcon, PlayerAppIconProvider (runtime icon lookup + cache)
// [POS]: Source-driven identity of "the music app" for UI that has to show it
//        (Settings tab icon / permission rows / product-name copy). Apple's
//        artwork is never bundled: the icon is whatever the system says the
//        INSTALLED app's icon is, resolved at runtime through
//        `urlForApplication(withBundleIdentifier:)` + `icon(forFile:)`; an app
//        that is not installed falls back to an SF Symbol. A future edition that
//        supports NetEase Cloud Music / QQ Music adds one more source (or one
//        more `PlayerAppIdentity` constant) and nothing in the UI changes.
// =============================================================================

/// Who the player app is, as the UI names and draws it.
public struct PlayerAppIdentity: Hashable, Sendable {
    /// LaunchServices bundle identifier, e.g. `com.apple.Music`.
    public let bundleIdentifier: String
    /// Product name used in copy: "Apple Music".
    public let displayName: String
    /// The application's own name, as macOS lists it under Automation: "Music".
    public let applicationName: String
    /// SF Symbol shown when the app is not installed.
    public let fallbackSymbolName: String

    public init(bundleIdentifier: String, displayName: String, applicationName: String? = nil, fallbackSymbolName: String = "music.note") {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationName = applicationName ?? displayName
        self.fallbackSymbolName = fallbackSymbolName
    }
}

extension PlayerAppIdentity {
    public static let appleMusic = PlayerAppIdentity(
        bundleIdentifier: "com.apple.Music", displayName: "Apple Music", applicationName: "Music")
    public static let spotify = PlayerAppIdentity(
        bundleIdentifier: "com.spotify.client", displayName: "Spotify")
    public static let neteaseCloudMusic = PlayerAppIdentity(
        bundleIdentifier: "com.netease.163music", displayName: "NetEase Cloud Music")
    public static let qqMusic = PlayerAppIdentity(
        bundleIdentifier: "com.tencent.QQMusicMac", displayName: "QQ Music")
}

/// What the UI should draw for a player app.
public struct PlayerAppIcon {
    public let image: NSImage
    /// True when the app was not found and `image` is the identity's SF Symbol (template).
    public let isFallbackSymbol: Bool
}

/// Resolves and caches player app icons. The two lookups are injectable so tests
/// never depend on what happens to be installed.
@MainActor
public final class PlayerAppIconProvider {

    public static let shared = PlayerAppIconProvider()

    private let locateApp: (String) -> URL?
    private let loadIcon: (URL) -> NSImage
    private var cache: [String: NSImage?] = [:]

    public init(
        locateApp: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        loadIcon: @escaping (URL) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.path) }
    ) {
        self.locateApp = locateApp
        self.loadIcon = loadIcon
    }

    /// The installed app's icon at `size` points (a copy: the cached original is never resized),
    /// or the identity's SF Symbol when the app is not installed. The lookup is cached per
    /// bundle identifier (hits and misses alike); `reset()` forgets it.
    public func icon(for identity: PlayerAppIdentity, size: CGFloat) -> PlayerAppIcon {
        if let app = appImage(for: identity) {
            let copy = (app.copy() as? NSImage) ?? app
            copy.size = NSSize(width: size, height: size)
            copy.isTemplate = false
            return PlayerAppIcon(image: copy, isFallbackSymbol: false)
        }
        let symbol = NSImage(systemSymbolName: identity.fallbackSymbolName, accessibilityDescription: identity.displayName)
            ?? NSImage(size: NSSize(width: size, height: size))
        return PlayerAppIcon(image: symbol, isFallbackSymbol: true)
    }

    public func reset() { cache.removeAll() }

    private func appImage(for identity: PlayerAppIdentity) -> NSImage? {
        if let cached = cache[identity.bundleIdentifier] { return cached }
        let resolved = locateApp(identity.bundleIdentifier).map(loadIcon)
        cache[identity.bundleIdentifier] = .some(resolved)
        return resolved
    }
}
