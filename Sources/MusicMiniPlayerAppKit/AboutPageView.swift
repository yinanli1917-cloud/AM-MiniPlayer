/**
 * [INPUT]: Depends on LocalizedStrings' L10n; SettingsPalette (accent);
 *          Bundle.main for the version string; NSApp's application icon.
 * [OUTPUT]: Exports AboutHeaderView (icon + name + version, sits in the stage
 *           slot) and AboutLinksView (tagline + three links, sits in the page
 *           slot).
 * [POS]: Settings window's About tab (docs/design/2026-09-25-menu-settings/
 *        proposal.md §4.3 "About" row + mockup `.about`) — a deliberate
 *        placeholder, no animation; the animation session replaces it. The
 *        native toolbar-tab strip stays where it is on every tab.
 */

import SwiftUI
import AppKit

enum AboutInfo {
    static let githubURL = URL(string: "https://github.com/yinanli1917-cloud/AM-MiniPlayer")!

    static var marketingVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}

/// `.about .appicon` 64pt, `.name` 17 semibold, `.ver` 11 secondary.
struct AboutHeaderView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
            Text("nanoPod")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 2)
            Text("\(L10n.localized("version")) \(AboutInfo.marketingVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.about .tag` 13 secondary, `.links` 12pt in the accent colour.
struct AboutLinksView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text(L10n.localized("aboutTagline"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link("GitHub", destination: AboutInfo.githubURL)
                Link(L10n.localized("acknowledgements"), destination: AboutInfo.githubURL.appending(path: "blob/main/CLAUDE.md"))
                Link(L10n.localized("reportIssue"), destination: AboutInfo.githubURL.appending(path: "issues/new"))
            }
            .font(.system(size: 12))
            .foregroundStyle(SettingsPalette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}
