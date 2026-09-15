/**
 * [INPUT]: MusicController (播放状态 + 歌单数据 + 封面缓存)
 * [OUTPUT]: PlaylistView (歌单页面视图)
 * [POS]: UI/ 的歌单页面，与 MiniPlayerView 通过 Binding 交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import AppKit

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistView
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 macOS 26 修复：不用 Section + LazyVStack + pinnedViews（会触发递归 bug）
// 🔑 Sticky Header：全局 overlay + PreferenceKey 追踪 section 位置
// 🔑 Gemini 方案：header 纯文字透明，歌单行滚动到 header 区域时自己模糊
// 🔑 自由滚动：不用 snap scroll，让用户自由浏览（snap 会让每行都卡住）

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PreferenceKey for Section Tracking
// ═══════════════════════════════════════════════════════════════════════════════

struct SectionOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

public struct PlaylistView: View {
    @EnvironmentObject var musicController: MusicController

    #if DEBUG
    /// Counts real SwiftUI `body` invocations. Not read anywhere in production —
    /// exists so PlaylistViewRenderChurnTests can measure re-render frequency
    /// deterministically (a real NSWindow-hosted headless probe) instead of
    /// guessing from static reading. See the 2026-09-15 CPU-regression fix at
    /// the Up Next section below (WT-D plan H postmortem) for why this exists.
    public static var debugBodyEvalCount = 0
    #endif

    // ═══════════════════════════════════════════
    // MARK: - Bindings（与 MiniPlayerView 同步）
    // ═══════════════════════════════════════════
    @Binding var currentPage: PlayerPage
    @Binding var selectedTab: Int
    @Binding var showControls: Bool
    @Binding var isHovering: Bool
    @Binding var showOverlayContent: Bool

    var animationNamespace: Namespace.ID
    var effectArtwork: NSImage?

    // ═══════════════════════════════════════════
    // MARK: - Local State
    // ═══════════════════════════════════════════
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var isCoverAnimating: Bool = false

    // 滚动控制状态
    @State private var scrollLocked: Bool = false
    @State private var hasTriggeredSlowScroll: Bool = false

    // 控件显示状态
    @State private var controlsVisible: Bool = false

    // 全屏封面模式
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    // Repeat animation flow
    @State private var repeatFlow: CGFloat = 0

    // Sticky header 状态
    @State private var sectionOffsets: [String: CGFloat] = [:]

    // D1: 点行跳曲后的等待态——点击即显，换曲确认/失败/4s 超时清除。
    // 放列表容器一层，行重建（滚动回收）时状态不丢。
    @State private var pendingJump: JumpToPendingState? = nil

    // ═══════════════════════════════════════════
    // MARK: - Constants
    // ═══════════════════════════════════════════
    private let artSizeRatio: CGFloat = 0.18
    private let artSizeMax: CGFloat = 60.0
    private let headerHeight: CGFloat = 32

    // ═══════════════════════════════════════════
    // MARK: - Init
    // ═══════════════════════════════════════════
    public init(
        currentPage: Binding<PlayerPage>,
        animationNamespace: Namespace.ID,
        selectedTab: Binding<Int>,
        showControls: Binding<Bool>,
        isHovering: Binding<Bool>,
        showOverlayContent: Binding<Bool>,
        effectArtwork: NSImage? = nil
    ) {
        self._currentPage = currentPage
        self.animationNamespace = animationNamespace
        self._selectedTab = selectedTab
        self._showControls = showControls
        self._isHovering = isHovering
        self._showOverlayContent = showOverlayContent
        self.effectArtwork = effectArtwork
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Body
    // ═══════════════════════════════════════════════════════════════════════════════
    public var body: some View {
        #if DEBUG
        let _ = Self.debugBodyEvalCount += 1
        #endif
        GeometryReader { geometry in
            let artSize = min(geometry.size.width * artSizeRatio, artSizeMax)
            let rowArtSize = min(geometry.size.width * 0.12, 40.0)

            ZStack(alignment: .top) {
                // ═══════════════════════════════════════════
                // MARK: - Background
                // ═══════════════════════════════════════════
                PanelBackdrop(artwork: effectArtwork ?? musicController.currentArtwork, role: .pageOverlay)
                    .ignoresSafeArea()

                // ═══════════════════════════════════════════
                // MARK: - Main ScrollView with Sections
                // ═══════════════════════════════════════════
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {

                            // ═══════════════════════════════════════════
                            // MARK: - History Section（有 sticky header）
                            // ═══════════════════════════════════════════
                            PlaylistSection(
                                sectionID: "history",
                                title: PlaylistL10n.localized("history"),
                                headerHeight: headerHeight
                            ) {
                                if displayedPlaybackHistory.isEmpty {
                                    emptyStateText(PlaylistL10n.localized("noRecentTracks"))
                                } else {
                                    // Real playback history nanoPod itself observed (founder
                                    // ruling 2026-09-13) — already newest-first, unlike the
                                    // legacy `recentTracks` (Apple Music account "recently
                                    // played", kept fetching but no longer read by this
                                    // section — WT-E still calls the public API for it).
                                    // 2026-09-15: the currently PLAYING track is filtered out
                                    // of this display list (`displayedPlaybackHistory`) — it
                                    // already has its own row on the Now Playing card; History
                                    // is "what played before," and showing it here a second
                                    // time was also what kept its waveform symbolEffect row
                                    // mounted (and animating at 60fps) the instant playback
                                    // started, even off the Playlist page. The STORE still
                                    // records every confirmed track change unfiltered — this
                                    // filter is display-layer only.
                                    ForEach(displayedPlaybackHistory) { entry in
                                        PlaylistItemRowCompact(
                                            track: (
                                                title: entry.title,
                                                artist: entry.artist,
                                                album: entry.album,
                                                persistentID: entry.persistentID,
                                                duration: entry.duration
                                            ),
                                            artSize: rowArtSize,
                                            currentPage: $currentPage,
                                            isScrolling: isManualScrolling,
                                            fadeHeaderHeight: headerHeight,
                                            pendingJump: $pendingJump,
                                            isDisabled: entry.sourceKind == .radioOrStream,
                                            allowsScriptingBridgeArtworkLookup: RowArtworkSourceGate.allowsScriptingBridgeLookup(sourceKind: entry.sourceKind)
                                        )
                                    }
                                }
                            }
                            .id("historySection")

                            // ═══════════════════════════════════════════
                            // MARK: - Now Playing Section（普通标题，不 sticky）
                            // ═══════════════════════════════════════════
                            PlainHeaderSection(
                                title: PlaylistL10n.localized("nowPlaying"),
                                headerHeight: headerHeight
                            ) {
                                nowPlayingCard(geometry: geometry, artSize: artSize)
                            }
                            .id("nowPlayingSection")

                            // ═══════════════════════════════════════════
                            // MARK: - Up Next Section（有 sticky header）
                            // ═══════════════════════════════════════════
                            // Founder ruling 2026-09-13: Up Next renders ONLY when it is
                            // provably exact (library playlist context + shuffle off);
                            // otherwise the section shows a single fixed caption instead of
                            // its track list — no flicker between the two.
                            //
                            // 2026-09-15 CPU-regression fix (WT-D plan H postmortem): the
                            // shown/hidden branch used to switch OUTSIDE PlaylistSection
                            // (`if ... { PlaylistSection(...) } else { caption }`), so every
                            // time `upNextVisibility` merely re-evaluated to the SAME value —
                            // which happens on every unrelated MusicController @Published
                            // write, since @EnvironmentObject invalidates this whole body
                            // regardless of which property changed (headless-proven: 20
                            // redundant writes -> 20 body re-evaluations, identical before
                            // and after this gate existed) — SwiftUI saw two structurally
                            // different view types and tore down/rebuilt PlaylistSection's
                            // GeometryReader/.preference sticky-header plumbing every time
                            // (the same "destroyed/recreated" trap banned-patterns.md already
                            // documents for conditional ScrollView rendering). Keeping
                            // PlaylistSection itself unconditional and branching only its
                            // CONTENT (same shape as the History section just above) keeps
                            // that plumbing's identity stable across re-renders regardless of
                            // how often body re-runs.
                            PlaylistSection(
                                sectionID: "upNext",
                                title: PlaylistL10n.localized("upNext"),
                                headerHeight: headerHeight,
                                showsHeader: upNextVisibility == .shown
                            ) {
                                if upNextVisibility == .shown {
                                    if musicController.upNextTracks.isEmpty {
                                        emptyStateText(PlaylistL10n.localized(
                                            UpNextEmptyState.messageKey(
                                                provenance: musicController.queueProvenance,
                                                isEmpty: musicController.upNextTracks.isEmpty
                                            )
                                        ))
                                    } else {
                                        ForEach(musicController.upNextTracks, id: \.persistentID) { track in
                                            PlaylistItemRowCompact(
                                                track: track,
                                                artSize: rowArtSize,
                                                currentPage: $currentPage,
                                                isScrolling: isManualScrolling,
                                                fadeHeaderHeight: headerHeight,
                                                pendingJump: $pendingJump
                                            )
                                        }
                                    }
                                } else {
                                    upNextHiddenCaption
                                }
                            }
                            .id("upNextSection")

                            // 底部留白
                            Spacer().frame(height: 120)
                        }
                    }
                    // 🔑 topFadeHeight 只在有 sticky header 时启用
                    // 否则 Now Playing 在默认位置（顶部）时文字也被淡出
                    .modifier(BottomFadeMask(isActive: controlsVisible, topFadeHeight: computeStickyHeader() != nil ? 50 : 0))
                    .coordinateSpace(name: "playlistScroll")
                    .onPreferenceChange(SectionOffsetKey.self) { offsets in
                        sectionOffsets = offsets
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                        }
                    }
                    .onChange(of: currentPage) { _, newPage in
                        if newPage == .playlist {
                            scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                            showControlsWithAnimation()
                        }
                    }
                    .onChange(of: musicController.currentTrackTitle) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                scrollProxy.scrollTo("nowPlayingSection", anchor: .top)
                            }
                        }
                    }
                }
                .scrollDetectionWithVelocity(
                    onScrollStarted: { handleScrollStarted() },
                    onScrollEnded: { handleScrollEnded() },
                    onScrollWithVelocity: { deltaY, velocity in handleScrollWithVelocity(deltaY: deltaY, velocity: velocity) },
                    onScrollOffsetChanged: { _ in },
                    isEnabled: currentPage == .playlist
                )
                // D1: a jump resolves the instant the controller confirms the new
                // current track — don't wait for the timeout poll below.
                .onChange(of: musicController.currentPersistentID) { _, newID in
                    if let pending = pendingJump, pending.persistentID == newID {
                        pendingJump = nil
                    }
                }
                // D1: the only other way a pending jump clears itself — no completion
                // ever arrives (e.g. Music.app never confirms). Polls at a low rate;
                // resolve/failure already clear it immediately elsewhere.
                .task(id: pendingJump?.persistentID) {
                    guard let pending = pendingJump else { return }
                    let remaining = JumpToPendingState.timeout - Date().timeIntervalSince(pending.startedAt)
                    let nanoseconds = UInt64(max(0, remaining) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled, pendingJump == pending else { return }
                    pendingJump = nil
                }

                // ═══════════════════════════════════════════
                // MARK: - Global Sticky Header Overlay
                // ═══════════════════════════════════════════
                // 🔑 根据 section offset 决定显示哪个 sticky header
                // 🔑 只有当 section 滚动到顶部且还有内容在下方时才显示
                VStack {
                    if let stickyTitle = computeStickyHeader() {
                        Text(stickyTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .frame(height: headerHeight)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)

                // ═══════════════════════════════════════════
                // MARK: - Bottom Controls Overlay
                // ═══════════════════════════════════════════
                VStack {
                    Spacer()

                    ZStack(alignment: .bottom) {
                        // 🔑 已改用 BottomFadeMask，不需要模糊背景
                        Color.clear.frame(height: 1).allowsHitTesting(false)

                        SharedBottomControls(
                            timePublisher: musicController.timePublisher,
                            currentPage: $currentPage,
                            isHovering: $isHovering,
                            showControls: $showControls,
                            isProgressBarHovering: $isProgressBarHovering,
                            dragPosition: $dragPosition
                        )
                        .padding(.bottom, 0)
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                }
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : 20)
                .animation(.easeInOut(duration: 0.3), value: controlsVisible)
            }
            .onAppear {
                musicController.refreshQueueForPlaylistOpen()
            }
            .onHover { hovering in
                handleHover(hovering: hovering)
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
                if newValue != fullscreenAlbumCover {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        fullscreenAlbumCover = newValue
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Subviews
    // ═══════════════════════════════════════════════════════════════════════════════

    @ViewBuilder
    private func emptyStateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 20)
    }

    /// History section's display list: `playbackHistory` with the CURRENTLY
    /// PLAYING track filtered out (2026-09-15 CPU-regression fix, part 2 —
    /// see the call site and `isActiveForContinuousAnimation` above for why).
    /// `PlaybackHistoryStore` still records every confirmed track change
    /// unfiltered — `MusicController.clearPlaybackHistory()`/persistence are
    /// untouched; this is a pure display-layer filter. Guarded to non-empty
    /// `currentPersistentID` only: a radio/URL track's persistentID is "" like
    /// several PAST radio entries can also be, so blindly matching "" == ""
    /// would hide unrelated history rows, not just the current one.
    private var displayedPlaybackHistory: [PlaybackHistoryEntry] {
        PlaybackHistoryDisplayPolicy.displayed(
            history: musicController.playbackHistory,
            currentPersistentID: musicController.currentPersistentID
        )
    }

    /// Founder ruling 2026-09-13: whether the Up Next section may render at all.
    private var upNextVisibility: UpNextVisibility {
        UpNextVisibility.decide(
            provenance: musicController.queueProvenance,
            shuffleEnabled: musicController.shuffleEnabled
        )
    }

    /// One fixed caption line shown under the Now Playing card in place of the
    /// entire Up Next section when it is hidden. Stable text per reason — no
    /// animation beyond whatever default transition SwiftUI applies when the
    /// branch itself switches.
    @ViewBuilder
    private var upNextHiddenCaption: some View {
        if case .hidden(let reason) = upNextVisibility {
            let key = reason == .shuffle ? "upNextHiddenShuffle" : "upNextHiddenNoQueue"
            emptyStateText(PlaylistL10n.localized(key))
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Now Playing Card
    // ═══════════════════════════════════════════════════════════════════════════════
    @ViewBuilder
    private func nowPlayingCard(geometry: GeometryProxy, artSize: CGFloat) -> some View {
        if musicController.currentTrackTitle != kNotPlayingSentinel {
            VStack(spacing: 0) {
                Button(action: {
                    let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
                    withAnimation(.spring(response: animationDuration, dampingFraction: 0.85)) {
                        isCoverAnimating = true
                        currentPage = .album
                        isHovering = true
                        showControls = true
                        showOverlayContent = true
                    }
                }) {
                    HStack(alignment: .center, spacing: 12) {
                        if musicController.currentArtwork != nil {
                            Color.clear
                                .frame(width: artSize, height: artSize)
                                .clipShape(.rect(cornerRadius: 6))
                                .matchedGeometryEffect(id: "playlist-placeholder", in: animationNamespace, isSource: true)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: artSize, height: artSize)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(musicController.currentTrackTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .modifier(SkipTextTransition(
                                    text: musicController.currentTrackTitle,
                                    direction: musicController.skipDirection,
                                    offset: 20,
                                    maxBlur: 6
                                ))

                            Text(musicController.currentArtist)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .modifier(SkipTextTransition(
                                    text: musicController.currentArtist,
                                    direction: musicController.skipDirection,
                                    offset: 15,
                                    maxBlur: 4
                                ))
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Shuffle & Repeat buttons — only on playlist page
                if currentPage == .playlist {
                    HStack(spacing: 16) {
                        let themeColor = Color(red: 0.99, green: 0.24, blue: 0.27)

                        Spacer()

                        PlaylistControlButton(
                            action: { musicController.toggleShuffle() },
                            isEnabled: musicController.shuffleEnabled,
                            label: "Shuffle",
                            themeColor: themeColor
                        ) {
                            AnimatedShuffleIcon(
                                color: musicController.shuffleEnabled ? themeColor : .white,
                                isEnabled: musicController.shuffleEnabled,
                                size: 11,
                                weight: .regular
                            )
                        }

                        PlaylistControlButton(
                            action: { musicController.cycleRepeatMode() },
                            isEnabled: musicController.repeatMode > 0,
                            label: "Repeat",
                            themeColor: themeColor
                        ) {
                            Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                                .contentTransition(.symbolEffect(.replace))
                                .font(.system(size: 11))
                                .rotationEffect(.degrees(repeatFlow * 12))
                                .scaleEffect(1 - repeatFlow * 0.12)
                        }
                        .onChange(of: musicController.repeatMode) { _, _ in
                            withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) { repeatFlow = 1 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { repeatFlow = 0 }
                            }
                        }

                        Spacer()
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Event Handlers
    // ═══════════════════════════════════════════════════════════════════════════════

    private func handleScrollStarted() {
        isManualScrolling = true
        scrollLocked = false
        hasTriggeredSlowScroll = false
        autoScrollTimer?.invalidate()
    }

    private func handleScrollEnded() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            if !isHovering {
                hideControls()
            } else if !controlsVisible {
                showControlsWithAnimation()
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                isManualScrolling = false
                scrollLocked = false
                hasTriggeredSlowScroll = false
            }
        }
    }

    private func handleScrollWithVelocity(deltaY: CGFloat, velocity: CGFloat) {
        let absVelocity = abs(velocity)
        let threshold: CGFloat = 800

        if deltaY < 0 {
            if controlsVisible { hideControls() }
            scrollLocked = true
        } else if absVelocity >= threshold {
            if !scrollLocked { scrollLocked = true }
            if controlsVisible { hideControls() }
        } else if deltaY > 0 && !scrollLocked && !hasTriggeredSlowScroll {
            hasTriggeredSlowScroll = true
            if !controlsVisible { showControlsWithAnimation() }
        }
        // NOTE: deliberately no per-event @State write here. Writing an (unread) velocity into
        // @State on every scroll event invalidated this view → full SwiftUI re-layout each frame
        // during playlist scroll (same class of bug as LyricsView's removed scroll.lastVelocity).
    }

    private func handleHover(hovering: Bool) {
        guard currentPage == .playlist else { return }
        isHovering = hovering

        if !hovering {
            hideControls()
        } else if !isManualScrolling && !controlsVisible {
            showControlsWithAnimation()
        }
    }

    private func showControlsWithAnimation() {
        showControls = true
        controlsVisible = true
    }

    private func hideControls() {
        showControls = false
        controlsVisible = false
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MARK: - Sticky Header Logic
    // ═══════════════════════════════════════════════════════════════════════════════
    // 🔑 计算当前应该显示的 sticky header
    // 🔑 条件：section 已滚动到顶部（minY <= 0）且还有内容在视口内（底部未完全离开）

    private func computeStickyHeader() -> String? {
        let historyMinY = sectionOffsets["history_minY"] ?? 1000
        let historyMaxY = sectionOffsets["history_maxY"] ?? 1000
        let upNextMinY = sectionOffsets["upNext_minY"] ?? 1000
        let upNextMaxY = sectionOffsets["upNext_maxY"] ?? 1000

        if PlaylistStickyHeaderPolicy.shouldShow(minY: historyMinY, maxY: historyMaxY, headerHeight: headerHeight) {
            return "History"
        }

        if upNextVisibility == .shown,
           PlaylistStickyHeaderPolicy.shouldShow(minY: upNextMinY, maxY: upNextMaxY, headerHeight: headerHeight) {
            return "Up Next"
        }

        return nil
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistStickyHeaderPolicy
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 Pure layout policy: when should the global sticky header overlay stand in
// for a section's own inline header?
//
// A section reports its own frame (minY/maxY) in the shared "playlistScroll"
// coordinate space via SectionOffsetKey. At the ScrollView's natural resting
// position, the very first section's minY is already ~0 (flush with the
// viewport top) even though nothing has been scrolled — `minY <= 0` treated
// that as "already scrolled past top", so the sticky overlay could appear the
// instant the playlist page opened, drawn directly on top of the section's own
// (still fully visible) inline header and its body (e.g. the "No recent
// tracks" empty-state text sits right where the duplicate title renders).
//
// The inline header must have scrolled FULLY out of view — not merely started
// to move — before the fixed duplicate takes its place, so the two never
// occupy the same pixels regardless of how tall the section's body is (a
// short empty-state body reserves exactly `headerHeight` like any other body).
enum PlaylistStickyHeaderPolicy {
    static func shouldShow(minY: CGFloat, maxY: CGFloat, headerHeight: CGFloat) -> Bool {
        minY <= -headerHeight && maxY > headerHeight
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistSection
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 避免 Section + pinnedViews 的递归 bug (POSTM-001)
// 🔑 用 PreferenceKey 报告 section 位置给父视图
// 🔑 内部 header 在 section 未滚动时显示，滚动后由全局 overlay 接管

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - UpNextEmptyState
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 Pure decision (no SwiftUI): which PlaylistL10n key explains an empty Up Next?
// Only .noPublicQueueObject / .noCurrentPlaylistForTrackClass mean Music.app
// actively exposed no queue for this source (radio / Apple Music streaming URL)
// — say so instead of a generic "empty". Every other unavailable reason (startup
// default, no current track, app unavailable, pending refresh) is not a source
// limitation and must not claim one.

enum UpNextEmptyState {
    static func messageKey(provenance: MusicQueueProvenance, isEmpty: Bool) -> String {
        guard isEmpty else { return "queueEmpty" }
        switch provenance {
        case .unavailable(reason: .noPublicQueueObject),
             .unavailable(reason: .noCurrentPlaylistForTrackClass):
            return "queueUnavailableForSource"
        default:
            return "queueEmpty"
        }
    }
}

struct PlaylistSection<Content: View>: View {
    let sectionID: String
    let title: String
    let headerHeight: CGFloat
    /// False renders this section with NO inline header row (no title, no
    /// height reservation for one) while keeping the section's own identity —
    /// and its sticky-header GeometryReader/.preference plumbing — unchanged.
    /// Used by the Up Next section's hidden/caption state (see call site):
    /// the caption stands in for the WHOLE section including its title, but
    /// must not force SwiftUI to tear down and rebuild the section itself
    /// just because the title visibility flipped.
    var showsHeader: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header（在 section 内部，滚出视口后由全局 overlay 接管）
            if showsHeader {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(height: headerHeight)
            }

            // 内容
            content
        }
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named("playlistScroll"))
                Color.clear
                    .preference(
                        key: SectionOffsetKey.self,
                        value: [
                            "\(sectionID)_minY": frame.minY,
                            "\(sectionID)_maxY": frame.maxY
                        ]
                    )
            }
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlainHeaderSection
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 普通标题（不 sticky），用于 Now Playing

struct PlainHeaderSection<Content: View>: View {
    let title: String
    let headerHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(height: headerHeight)

            content
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistItemRowCompact
// ═══════════════════════════════════════════════════════════════════════════════

struct PlaylistItemRowCompact: View {
    let track: (title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)
    let artSize: CGFloat
    @Binding var currentPage: PlayerPage
    var isScrolling: Bool = false
    var fadeHeaderHeight: CGFloat = 0
    @Binding var pendingJump: JumpToPendingState?
    /// Radio/stream history rows: cannot be jumped to (no stable identity to
    /// resume), shown disabled — dimmed, no hover cursor, tap does nothing.
    var isDisabled: Bool = false
    /// Whether this row's persistentID is a real library entry that a local
    /// ScriptingBridge scan could plausibly resolve. History rows carry an
    /// explicit `sourceKind` (only `.library` qualifies — a radio/stream row
    /// has no local identity, and an Apple Music CATALOG row's "am:"-prefixed
    /// id was never in `currentPlaylist`/the local library either). Up Next
    /// rows come straight off Music.app's live SB queue, so they're always
    /// library-eligible. Gates ONLY the last-resort SB tier in `loadArtwork`
    /// — the RowArtworkStore network tier still runs for every row.
    var allowsScriptingBridgeArtworkLookup: Bool = true

    @State private var isHovering = false
    @State private var isCursorPushed = false
    @State private var artwork: NSImage? = nil
    @State private var currentArtworkID: String = ""
    @EnvironmentObject var musicController: MusicController

    private var isCurrentTrack: Bool {
        track.persistentID == musicController.currentPersistentID
    }

    /// 2026-09-15 CPU-regression fix (WT-D plan H postmortem, part 2 — real
    /// sample evidence): the waveform icon's `.symbolEffect(.variableColor.
    /// iterative, isActive:)` is a genuinely continuous 60fps animation
    /// (`-[RBLayer display]` every frame on the main thread). PlaylistView
    /// never leaves the view tree (banned-patterns.md), so before plan H this
    /// was harmless — `recentTracks`/`upNextTracks` never included the
    /// CURRENTLY PLAYING track (History showed only earlier tracks, Up Next
    /// only later ones), so `isCurrentTrack` was never true for any mounted
    /// row and the animation never started. Once History started showing real
    /// playback history (its most recent entry IS the track that just started
    /// playing), the row for the current track mounts with `isCurrentTrack ==
    /// true` immediately — including while the Playlist page is not visible
    /// (Lyrics/Album pages showing) — and the animation ran 60fps in the
    /// background indefinitely. Generalized gate: ANY continuous animation in
    /// a playlist row must also require the Playlist page to be on screen —
    /// same `currentPage` visibility signal as the row-artwork-storm fix
    /// (`RowArtworkVisibilityPolicy.shouldFetch`).
    private var isActiveForContinuousAnimation: Bool {
        PlaylistRowContinuousAnimationPolicy.isActive(isPlaying: musicController.isPlaying, currentPage: currentPage)
    }

    // D1: this row's own jump-to-tap feedback — shows while the tap is in
    // flight, clears on resolve/failure/timeout (all decided by the container).
    private var isPendingJump: Bool {
        pendingJump?.persistentID == track.persistentID
    }

    var body: some View {
        Button(action: {
            guard !isDisabled else { return }
            if isCurrentTrack {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentPage = .album
                }
            } else {
                let id = track.persistentID
                pendingJump = JumpToPendingState(persistentID: id, startedAt: Date())
                musicController.playTrack(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    persistentID: id
                ) { success in
                    if !success {
                        pendingJump = JumpToPendingState.clearingOnFailure(current: pendingJump, failedID: id)
                    }
                }
            }
        }) {
            HStack(spacing: 8) {
                if let artwork = artwork, currentArtworkID == track.persistentID {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artSize, height: artSize)
                        .clipShape(.rect(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: artSize, height: artSize)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: artSize * 0.35))
                                .foregroundStyle(.white.opacity(0.3))
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 11, weight: isCurrentTrack ? .bold : .medium))
                        .foregroundStyle(isCurrentTrack ? Color(red: 0.99, green: 0.24, blue: 0.27) : .white)
                        .opacity(isPendingJump ? 0.6 : 1.0)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                if isPendingJump {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                } else if isCurrentTrack {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.99, green: 0.24, blue: 0.27))
                        .symbolEffect(.variableColor.iterative, isActive: isActiveForContinuousAnimation)
                        .padding(.trailing, 8)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
        .onHover { hovering in
            guard !isScrolling, !isDisabled else { return }
            withAnimation(.smooth(duration: 0.2)) {
                isHovering = hovering
            }
            setCursorPushed(hovering)
        }
        .onChange(of: isScrolling) { _, scrolling in
            // 🔑 discoverability cursor must not stay stuck once a scroll starts
            // under the pointer — pop it the same way onHover would have.
            if scrolling {
                isHovering = false
                setCursorPushed(false)
            }
        }
        .onDisappear {
            setCursorPushed(false)
        }
        // 🔑 2026-09-15 artwork-storm fix: id carries page-visibility, not just
        // identity. `PlaylistView` never leaves the tree (banned-patterns.md)
        // and History/Up Next are a plain (non-lazy) VStack, so EVERY row used
        // to fetch the instant it mounted — including when `playbackHistory`
        // jumps from empty to its full persisted list on the first confirmed
        // track change. Folding visibility into the task id means the task is
        // a no-op while off-screen and fires (once, on-demand) the moment the
        // Playlist page becomes visible. See RowArtworkVisibilityPolicy.
        .task(id: RowArtworkTaskKey(
            persistentID: track.persistentID,
            visible: RowArtworkVisibilityPolicy.shouldFetch(currentPage: currentPage)
        )) {
            guard RowArtworkVisibilityPolicy.shouldFetch(currentPage: currentPage) else { return }
            await loadArtwork()
        }
    }

    /// Pushes/pops NSCursor.pointingHand exactly once per hover-in/out so repeated
    /// calls (onHover re-entrancy, onChange, onDisappear) never leave the cursor
    /// stack unbalanced.
    private func setCursorPushed(_ pushed: Bool) {
        guard pushed != isCursorPushed else { return }
        isCursorPushed = pushed
        if pushed {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// 2026-09-15 artwork-storm fix. Tier order changed from "SB scan first"
    /// to "RowArtworkStore's memory→disk→single-flight-network first, SB scan
    /// only as a library-only last resort" — the SB scan is the expensive one
    /// (ScriptingBridge Apple Events, ~0.9s/call, serialized on one queue; see
    /// RowArtworkFetchPolicy.swift). Concurrency is bounded by
    /// `rowArtworkFetchGate` (2-3 rows in flight at once, not N-at-once), and
    /// a terminal failure backs off via `rowArtworkNegativeCache` instead of
    /// the old unconditional "sleep 8s, retry once".
    private func loadArtwork() async {
        let pid = track.persistentID
        guard currentArtworkID != pid else { return }

        currentArtworkID = pid
        artwork = nil

        // Free fast path: memory only, no I/O, always safe regardless of tier.
        if let cached = musicController.getCachedArtwork(persistentID: pid) {
            artwork = cached
            return
        }

        let negativeCacheKey = pid.isEmpty ? "meta:\(track.title)|\(track.artist)|\(track.album)" : pid
        guard !musicController.rowArtworkNegativeCache.shouldSkip(key: negativeCacheKey) else { return }

        await musicController.rowArtworkFetchGate.acquire()
        defer { musicController.rowArtworkFetchGate.release() }
        // Re-check identity: this row may have been recycled to a different
        // track while it waited for a gate slot.
        guard currentArtworkID == pid else { return }

        // Tier 1: RowArtworkStore's memory → disk (Apple tier, then web tier)
        // → single-flighted network fetch. Runs for every row, library or not.
        if let img = await musicController.fetchMusicKitArtwork(
            title: track.title, artist: track.artist, album: track.album
        ) {
            musicController.rowArtworkNegativeCache.recordSuccess(key: negativeCacheKey)
            if !pid.isEmpty {
                musicController.cacheRowArtworkByPersistentID(img, persistentID: pid)
            }
            await MainActor.run { if currentArtworkID == pid { artwork = img } }
            return
        }

        // Tier 2 (last resort, library tracks only): ScriptingBridge scan by
        // persistentID. Non-library rows (radio/stream, Apple Music catalog
        // streams) skip this — their id was never in `currentPlaylist` or the
        // local library, so the scan is guaranteed wasted Apple Event traffic.
        if allowsScriptingBridgeArtworkLookup, !pid.isEmpty,
           let localImg = await musicController.fetchArtworkByPersistentID(persistentID: pid) {
            musicController.rowArtworkNegativeCache.recordSuccess(key: negativeCacheKey)
            await MainActor.run { if currentArtworkID == pid { artwork = localImg } }
            return
        }

        // Terminal: every eligible tier missed. Back off instead of a blind retry.
        musicController.rowArtworkNegativeCache.recordFailure(key: negativeCacheKey)
    }
}

/// Task identity for a playlist row's artwork fetch: folds page visibility
/// into the `.task(id:)` key (see RowArtworkVisibilityPolicy) so the task is
/// a cheap no-op while the row is off-screen and fires once, on demand, the
/// moment the Playlist page becomes visible.
struct RowArtworkTaskKey: Equatable {
    let persistentID: String
    let visible: Bool
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - BottomFadeMask
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 底部渐隐遮罩：替代 VisualEffectView 模糊背景，更轻量且无色差

struct BottomFadeMask: ViewModifier {
    var isActive: Bool
    var topFadeHeight: CGFloat = 0
    var steepFade: Bool = false

    func body(content: Content) -> some View {
        content
            .mask(
                VStack(spacing: 0) {
                    if topFadeHeight > 0 {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: topFadeHeight)
                    }
                    Color.black
                    ZStack {
                        LinearGradient(
                            gradient: Gradient(stops: steepFade ? [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.15), location: 0.3),
                                .init(color: .clear, location: 0.5)
                            ] : [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.4), location: 0.35),
                                .init(color: .clear, location: 0.75)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        Color.black.opacity(isActive ? 0 : 1)
                    }
                    .frame(height: 160)
                }
            )
            .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ScrollFadeEffect
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 Gemini 方案：歌单行滚动到 header 区域时自己模糊+淡出

struct ScrollFadeEffect: ViewModifier {
    let headerHeight: CGFloat
    var isScrolling: Bool = false

    func body(content: Content) -> some View {
        if headerHeight > 0 {
            content
                .visualEffect { effectContent, geometryProxy in
                    let frame = geometryProxy.frame(in: .named("playlistScroll"))
                    let minY = frame.minY
                    // 🔑 当行滚动到 header 区域内时开始模糊
                    let progress = max(0, min(1, 1 - (minY / headerHeight)))

                    return effectContent
                        .blur(radius: progress * 8)
                        .opacity(1.0 - (progress * 0.4))
                }
        } else {
            content
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Preview
// ═══════════════════════════════════════════════════════════════════════════════

#if DEBUG
struct PlaylistView_Previews: PreviewProvider {
    @Namespace static var namespace
    static var previews: some View {
        PlaylistView(
            currentPage: .constant(.playlist),
            animationNamespace: namespace,
            selectedTab: .constant(1),
            showControls: .constant(true),
            isHovering: .constant(false),
            showOverlayContent: .constant(true)
        )
        .environmentObject(MusicController(preview: true))
        .frame(width: 300, height: 300)
    }
}
#endif
