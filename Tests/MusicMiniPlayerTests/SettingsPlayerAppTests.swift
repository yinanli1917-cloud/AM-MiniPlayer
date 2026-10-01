// ──────────────────────────────────────────────
// SettingsPlayerAppTests — the music app's identity and icon in Settings: the identity comes
// from the playback source, the icon is resolved at runtime from the INSTALLED app (never
// bundled), a missing app falls back to the SF Symbol, lookups are cached, and product-name
// copy follows the identity. The locate / load seams are injected; the one real-NSWorkspace
// test skips when Music.app is absent. Private defaults suites only.
// ──────────────────────────────────────────────

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

private final class NoopSpotifyReader: SpotifyScriptingReading {
    var isRunning = false
    func readState() -> SpotifyPlayerState? { nil }
    func perform(_ command: SpotifyCommand) {}
}

@MainActor
final class SettingsPlayerAppTests: XCTestCase {

    override func tearDown() {
        L10n.languageOverride = nil
        super.tearDown()
    }

    private func solidIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        image.unlockFocus()
        return image
    }

    // MARK: identity comes from the source

    func test_identity_isDrivenBySource() {
        XCTAssertEqual(SpotifyPlaybackSource(reader: NoopSpotifyReader()).appIdentity.bundleIdentifier, "com.spotify.client")
        XCTAssertEqual(PlayerAppIdentity.appleMusic.bundleIdentifier, "com.apple.Music")
        XCTAssertEqual(PlayerAppIdentity.appleMusic.displayName, "Apple Music")
        XCTAssertEqual(PlayerAppIdentity.appleMusic.applicationName, "Music")
        XCTAssertEqual(PlayerAppIdentity.neteaseCloudMusic.bundleIdentifier, "com.netease.163music")
    }

    func test_registry_activeAppIdentity_followsTheActiveSource() throws {
        let suite = "SettingsPlayerAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = PlaybackSourceRegistry(defaults: defaults)
        XCTAssertEqual(registry.activeAppIdentity, .appleMusic, "nothing registered: Apple Music")
        registry.register(SpotifyPlaybackSource(reader: NoopSpotifyReader()))
        XCTAssertEqual(registry.activeAppIdentity, .appleMusic, "preferred is still Apple Music")
        registry.select(.spotify)
        XCTAssertEqual(registry.activeAppIdentity, .spotify)
    }

    // MARK: icon resolution

    func test_icon_installedApp_resolvesItsIcon_atTheRequestedSize_notTemplate() {
        var asked: [String] = []
        let provider = PlayerAppIconProvider(
            locateApp: { asked.append($0); return URL(fileURLWithPath: "/Applications/Fake.app") },
            loadIcon: { _ in self.solidIcon() })
        let icon = provider.icon(for: .appleMusic, size: 28)
        XCTAssertFalse(icon.isFallbackSymbol)
        XCTAssertEqual(asked, ["com.apple.Music"])
        XCTAssertEqual(icon.image.size, NSSize(width: 28, height: 28))
        XCTAssertFalse(icon.image.isTemplate)
    }

    func test_icon_missingApp_fallsBackToTheSymbol() {
        let provider = PlayerAppIconProvider(locateApp: { _ in nil }, loadIcon: { _ in XCTFail("no app, no load"); return NSImage() })
        let icon = provider.icon(for: .neteaseCloudMusic, size: 20)
        XCTAssertTrue(icon.isFallbackSymbol)
        XCTAssertEqual(PlayerAppIdentity.neteaseCloudMusic.fallbackSymbolName, "music.note")
    }

    func test_icon_lookupIsCached_perBundleIdentifier_andResizingACopyKeepsTheCachedOriginal() {
        var locates = 0, loads = 0
        let provider = PlayerAppIconProvider(
            locateApp: { _ in locates += 1; return URL(fileURLWithPath: "/Applications/Fake.app") },
            loadIcon: { _ in loads += 1; return self.solidIcon() })
        let small = provider.icon(for: .appleMusic, size: 20)
        let big = provider.icon(for: .appleMusic, size: 28)
        XCTAssertEqual(locates, 1)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(small.image.size.width, 20)
        XCTAssertEqual(big.image.size.width, 28)
        _ = provider.icon(for: .spotify, size: 20)
        XCTAssertEqual(locates, 2, "a different bundle id is a different lookup")
        provider.reset()
        _ = provider.icon(for: .appleMusic, size: 20)
        XCTAssertEqual(locates, 3)
    }

    func test_icon_missingApp_isCachedToo() {
        var locates = 0
        let provider = PlayerAppIconProvider(locateApp: { _ in locates += 1; return nil }, loadIcon: { _ in NSImage() })
        _ = provider.icon(for: .qqMusic, size: 20)
        _ = provider.icon(for: .qqMusic, size: 20)
        XCTAssertEqual(locates, 1)
    }

    func test_icon_realWorkspace_resolvesMusicApp_whenInstalled() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil else {
            throw XCTSkip("Music.app is not installed on this machine")
        }
        let icon = PlayerAppIconProvider().icon(for: .appleMusic, size: 28)
        XCTAssertFalse(icon.isFallbackSymbol, "com.apple.Music resolves through NSWorkspace")
        XCTAssertFalse(icon.image.isTemplate)
    }

    // MARK: toolbar tab

    func test_playerTab_usesTheAppIcon_otherTabsKeepTheirSymbols() {
        let installed = PlayerAppIconProvider(locateApp: { _ in URL(fileURLWithPath: "/x.app") }, loadIcon: { _ in self.solidIcon() })
        let image = SettingsTabViewController.tabImage(for: .player, playerApp: .appleMusic, provider: installed)
        XCTAssertEqual(image?.size, NSSize(width: SettingsTabViewController.appIconToolbarSize, height: SettingsTabViewController.appIconToolbarSize))
        XCTAssertEqual(image?.isTemplate, false)
        XCTAssertTrue((24...32).contains(SettingsTabViewController.appIconToolbarSize), "NSToolbarItem images are 24-32pt")

        let general = SettingsTabViewController.tabImage(for: .general, playerApp: .appleMusic, provider: installed)
        XCTAssertNotEqual(general?.size, image?.size, "the other tabs stay SF Symbols")

        let missing = PlayerAppIconProvider(locateApp: { _ in nil }, loadIcon: { _ in NSImage() })
        let fallback = SettingsTabViewController.tabImage(for: .player, playerApp: .appleMusic, provider: missing)
        XCTAssertNotNil(fallback, "not installed: the music.note symbol")
    }

    // MARK: copy

    func test_copy_namesThePlayerFromTheIdentity() {
        L10n.languageOverride = "en"
        XCTAssertEqual(L10n.localized("automation", player: .appleMusic), "Music Automation")
        XCTAssertEqual(L10n.localized("appleMusic", player: .appleMusic), "Apple Music")
        XCTAssertEqual(L10n.localized("aboutTagline", player: .appleMusic), "A menu bar companion for Apple Music.")
        XCTAssertEqual(L10n.localized("automation", player: .neteaseCloudMusic), "NetEase Cloud Music Automation")
        XCTAssertEqual(L10n.localized("appleMusic", player: .neteaseCloudMusic), "NetEase Cloud Music")
        L10n.languageOverride = "zh"
        XCTAssertEqual(L10n.localized("automation", player: .appleMusic), "Music 自动化")
        XCTAssertEqual(L10n.localized("aboutTagline", player: .qqMusic), "QQ Music 的菜单栏伙伴。")
    }

    func test_copy_noPlaceholderSurvivesInAnyLanguage() {
        for lang in ["en", "zh"] {
            L10n.languageOverride = lang
            for key in ["automation", "automationDesc", "appleMusic", "aboutTagline"] {
                let text = L10n.localized(key, player: .appleMusic)
                XCTAssertFalse(text.contains("{"), "\(key) [\(lang)]: \(text)")
            }
        }
    }
}
