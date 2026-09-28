/**
 * [INPUT]: Depends on LocalizedStrings' L10n; Bundle.main for the version string.
 * [OUTPUT]: Exports AboutPageView.
 * [POS]: Settings window's About tab (docs/design/2026-09-25-menu-settings/
 *        proposal.md §4.3 "About" row + §4.4: "无动画。整块区域预留给动画会话，
 *        实现放独立 AboutPageView") — a deliberate placeholder, no animation.
 */

import SwiftUI

struct AboutPageView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)

            Text("nanoPod")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text("\(L10n.localized("version")) \(Self.marketingVersion)")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 16) {
                Link(destination: Self.githubURL) {
                    Text("GitHub")
                }
                Link(destination: Self.githubURL.appending(path: "blob/main/CLAUDE.md")) {
                    Text(L10n.localized("acknowledgements"))
                }
                Link(destination: Self.githubURL.appending(path: "issues/new")) {
                    Text(L10n.localized("reportIssue"))
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.link)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
