/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 OnboardingState/MusicController；
 *          依赖 LocalizedStrings 的 L10n
 * [OUTPUT]: 导出 OnboardingWindowView（C6 首次启动引导页，非模态独立窗口）
 * [POS]: MusicMiniPlayerApp 的引导界面，视觉家族对齐 SettingsWindowView，
 *        不使用 Liquid Glass 材质（避免 glass-on-glass）
 */

import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - 页面枚举
// ──────────────────────────────────────────────

private enum OnboardingPage: Int, CaseIterable {
    case welcome
    case authorization
    case done
}

// ──────────────────────────────────────────────
// MARK: - 本地转场（SettingsTabTransition 不是本文件可直接复用的形状，
// 用一个等价的本地实现：`.smooth(0.22)` + Reduce Motion 时只用 opacity）
// ──────────────────────────────────────────────

private enum OnboardingTransition {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeInOut(duration: 0.16) : .smooth(duration: 0.22)
    }

    static func transition(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

// ──────────────────────────────────────────────
// MARK: - OnboardingWindowView
// ──────────────────────────────────────────────

struct OnboardingWindowView: View {
    @EnvironmentObject var musicController: MusicController
    @ObservedObject var onboardingState: OnboardingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page: OnboardingPage = .welcome
    @State private var movingForward = true

    /// 授权状态在窗口获得焦点时重新查询——从不在渲染路径里自己触发系统弹窗。
    @State private var musicKitStatus: OnboardingAuthorizationStatus = .notDetermined
    @State private var automationStatus: OnboardingAuthorizationStatus = .notDetermined

    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageContent(page)
                    .id(page)
                    .transition(OnboardingTransition.transition(forward: movingForward, reduceMotion: reduceMotion))
            }
            .animation(OnboardingTransition.animation(reduceMotion: reduceMotion), value: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            pageIndicator
                .padding(.top, 12)

            footerButtons
                .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 460, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshAuthorizationStatus() }
    }

    // MARK: - 页面内容

    @ViewBuilder
    private func pageContent(_ page: OnboardingPage) -> some View {
        switch page {
        case .welcome:
            welcomePage
        case .authorization:
            authorizationPage
        case .done:
            donePage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.localized("onboarding.welcome.title"))
                .font(.title2.bold())
            Text(L10n.localized("onboarding.welcome.body"))
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                featureRow(symbol: "menubar.rectangle", key: "onboarding.feature.menubar")
                featureRow(symbol: "text.quote", key: "onboarding.feature.lyrics")
                featureRow(symbol: "rectangle.righthalf.inset.filled.arrow.right", key: "onboarding.feature.edgehide")
                featureRow(symbol: "keyboard", key: "onboarding.feature.shortcuts")
            }
            .padding(.top, 6)

            Spacer()
        }
    }

    private func featureRow(symbol: String, key: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(L10n.localized(key))
                .font(.callout)
        }
    }

    private var authorizationPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.localized("onboarding.auth.title"))
                .font(.title2.bold())
            Text(L10n.localized("onboarding.auth.body"))
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                authorizationRow(
                    title: L10n.localized("musicKit"),
                    desc: L10n.localized("musicKitDesc"),
                    status: musicKitStatus,
                    action: {
                        Task {
                            await musicController.requestMusicKitAccess()
                            refreshAuthorizationStatus()
                        }
                    }
                )
                authorizationRow(
                    title: L10n.localized("onboarding.auth.automation"),
                    desc: L10n.localized("onboarding.auth.automationDesc"),
                    status: automationStatus,
                    action: {
                        onboardingState.requestAutomationAccess()
                        // Automation 授权是系统同步弹窗流程，弹窗关闭后再查询一次即可。
                        refreshAuthorizationStatus()
                    }
                )
            }

            Spacer()
        }
    }

    private func authorizationRow(
        title: String,
        desc: String,
        status: OnboardingAuthorizationStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                Text(statusLabel(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if status != .authorized {
                    Button(L10n.localized("onboarding.auth.request"), action: action)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusColor(_ status: OnboardingAuthorizationStatus) -> Color {
        switch status {
        case .authorized: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    private func statusLabel(_ status: OnboardingAuthorizationStatus) -> String {
        switch status {
        case .authorized: return L10n.localized("onboarding.auth.authorized")
        case .denied: return L10n.localized("onboarding.auth.denied")
        case .notDetermined: return L10n.localized("onboarding.auth.notDetermined")
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.localized("onboarding.done.title"))
                .font(.title2.bold())
            Text(L10n.localized("onboarding.done.body"))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 页脚

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases, id: \.self) { p in
                Circle()
                    .fill(p == page ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            if page != .welcome {
                Button(L10n.localized("onboarding.back")) {
                    movingForward = false
                    if let prev = OnboardingPage(rawValue: page.rawValue - 1) {
                        page = prev
                    }
                }
            }

            Spacer()

            if page == .done {
                Button(L10n.localized("onboarding.finish")) {
                    onboardingState.markCompleted()
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.localized("onboarding.next")) {
                    movingForward = true
                    if page == .authorization { refreshAuthorizationStatus() }
                    if let next = OnboardingPage(rawValue: page.rawValue + 1) {
                        page = next
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func refreshAuthorizationStatus() {
        musicKitStatus = onboardingState.musicKitStatus
        automationStatus = onboardingState.automationStatus
    }
}
