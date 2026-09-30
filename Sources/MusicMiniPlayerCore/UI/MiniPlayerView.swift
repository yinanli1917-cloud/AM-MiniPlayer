import SwiftUI
import QuartzCore

// Use the system SwiftUI transition to avoid the disappearing icon bug.
// PlayerPage lives in MusicController so the floating window and menu bar stay in sync.

public struct MiniPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    // Use musicController.currentPage instead of local page state so every surface stays synchronized.
    @State private var isHovering: Bool = false
    @State private var showControls: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var playlistSelectedTab: Int = 1  // 0 = History, 1 = Up Next
    @Namespace private var animation

    // Album text and masks fade in after hover begins.
    @State private var showOverlayContent: Bool = false

    // Album controls blur/move in separately from song metadata.
    @State private var controlsBlurAmount: CGFloat = 10
    @State private var controlsOffsetY: CGFloat = 30

    // Fullscreen album cover mode is mirrored from UserDefaults.
    @State private var fullscreenAlbumCover: Bool = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")

    // Artwork luminance drives button contrast.
    @State private var artworkBrightness: CGFloat = 0.5
    @State private var topLeftLuminance: CGFloat = 0.5
    @State private var topRightLuminance: CGFloat = 0.5
    @State private var artworkTone: ArtworkBackgroundToneMap = .neutral
    @State private var effectArtwork: NSImage?
    @State private var effectArtworkSignature: String = ""

    // Shuffle/repeat icon legibility ONLY (founder 2026-09-24, narrowed same day after
    // trying the whole-button-set version): gray icon — never black — when the pixels
    // directly under shuffle/repeat are too bright, solved to land exactly on the WCAG
    // 3:1 non-text contrast floor. Recomputed once per artwork change / fullscreen-cover
    // toggle — never per frame (ButtonIconLegibility.swift). The two top buttons and the
    // bottom play area (SharedBottomControls) went back to their pre-2026-09-24 rules and
    // no longer read this. The recompute itself runs off the main thread via
    // `buttonIconCoordinator` (2026-09-24 review: must not hitch a song change) — its
    // last-request-wins semantics drop a stale result from a superseded artwork/toggle;
    // until a new result lands the PREVIOUS tones stay on screen (never cleared/flashed
    // to white).
    @State private var buttonIconTones: [ButtonIconID: ButtonIconTone] = [:]
    @State private var buttonIconCoordinator = ButtonIconRefreshCoordinator()

    // `.tinted` arm (default, 2026-09-26): the shuffle/repeat circles' own fill
    // colour, sampled+darkened from the local backdrop so the icon can stay
    // permanently white (ButtonFillTint.swift). Populated/animated the same way
    // as `buttonIconTones` above, but only the arm MicroInteractionFeel.buttonFill
    // currently selects gets refreshed — see refreshButtonIconTones().
    @State private var buttonFillColors: [ButtonIconID: BackdropLegibilityBand.RGBColor] = [:]
    @State private var buttonFillCoordinator = ButtonFillRefreshCoordinator()
    @State private var lastKnownPanelSize: CGSize = CGSize(width: PanelWindowMetrics.defaultSize.width, height: PanelWindowMetrics.defaultSize.height)

    // Shuffle/repeat feedback animation progress.
    @State private var repeatFlow: Double = 0

    // Temporarily lock hover after page switches so onHover(false) does not cancel the transition.
    @State private var hoverLocked: Bool = false
    @State private var isAudioOutputMenuPresented: Bool = false

    var openWindow: OpenWindowAction?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?

    public init(openWindow: OpenWindowAction? = nil, onHide: (() -> Void)? = nil, onExpand: (() -> Void)? = nil) {
        self.openWindow = openWindow
        self.onHide = onHide
        self.onExpand = onExpand
    }

    public var body: some View {
        mainBody.modifier(ConditionalGlassContainer())
    }

    @ViewBuilder
    var mainBody: some View {
        GeometryReader { geometry in
            ZStack {
                // Background: defaults-switched fluid gradient / native glass experiment.
                // Founder 2026-09-25: glass/clear only show on the non-fullscreen album
                // page — PanelBackdrop reads no page state itself, so that condition is
                // computed here and passed in as a plain Bool.
                PanelBackdrop(
                    artwork: effectArtwork ?? musicController.currentArtwork,
                    isAlbumPageNonFullscreen: musicController.currentPage == .album && !fullscreenAlbumCover
                )
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                // Window drag layer: lets the user move the panel from empty areas.
                WindowDraggableView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)

                // C1 贴边形变 pill (research/c1-edge-morph-design-2026-09-12.md §3):
                // same ZStack level as PanelBackdrop/WindowDraggableView, above
                // the backdrop so the pill's glass renders over it, below the
                // page content (zIndex left at default 0, pages set 0/1 above).
                EdgeMorphHost()
                    .zIndex(2)

                // Pages are stacked so matchedGeometryEffect can move a single artwork image.

                // Lyrics is the only page with frame-driven word rendering. Keep it
                // unmounted while hidden so album/playlist pages do not pay that CPU cost.
                if musicController.currentPage == .lyrics {
                    LyricsView(currentPage: $musicController.currentPage, openWindow: openWindow, onHide: onHide, onExpand: onExpand)
                        .zIndex(1)
                        .transition(.opacity)
                }

                // Playlist stays mounted to support matchedGeometryEffect.
                // C2 三时钟：PlaylistView 内部文字/控件不可拆分（归属 WT-D，不改），
                // 其整页 opacity crossfade 就充当「material」层的角色。
                PlaylistView(currentPage: $musicController.currentPage, animationNamespace: animation, selectedTab: $playlistSelectedTab, showControls: $showControls, isHovering: $isHovering, showOverlayContent: $showOverlayContent, effectArtwork: effectArtwork)
                    .opacity(musicController.currentPage == .playlist ? 1 : 0)
                    .zIndex(musicController.currentPage == .playlist ? 1 : 0)
                    .allowsHitTesting(musicController.currentPage == .playlist)
                    .animation(pageSwitchAnimations.material, value: musicController.currentPage)

                // Album stays mounted to support matchedGeometryEffect. It only
                // hosts the hero placeholder, so it rides the geometry clock.
                albumPageContent(geometry: geometry)
                    .opacity(musicController.currentPage == .album ? 1 : 0)
                    .zIndex(musicController.currentPage == .album ? 1 : 0)
                    .allowsHitTesting(musicController.currentPage == .album)
                    .animation(pageSwitchAnimations.geometry, value: musicController.currentPage)

                // Floating artwork: one clear hero image moved through matchedGeometryEffect — geometry clock.
                if let artwork = musicController.currentArtwork {
                    floatingArtwork(artwork: artwork, effectArtwork: effectArtwork ?? artwork, geometry: geometry)
                        .zIndex(musicController.currentPage == .album ? 50 : 1)
                        .animation(pageSwitchAnimations.geometry, value: musicController.currentPage)
                        .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
                        .accessibilityHidden(true)
                }

                // Album text and masks stay above floating artwork — this IS the
                // page's textual/control content, so it rides the content clock
                // (lagging geometry slightly per the three-clock plan).
                albumOverlayContent(geometry: geometry)
                    .zIndex(101)
                    .opacity(musicController.currentPage == .album ? 1 : 0)
                    .allowsHitTesting(musicController.currentPage == .album)
                    .animation(pageSwitchAnimations.content, value: musicController.currentPage)
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)


            }
            .modifier(FloatingMenuBackdropBlur(
                isActive: isAudioOutputMenuPresented,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion
            ))
            // Cache the panel's live size for the next artwork-change legibility
            // recompute (ButtonIconLegibility). This itself never triggers a
            // recompute — only currentArtwork/fullscreenAlbumCover changes do.
            .onAppear { lastKnownPanelSize = geometry.size }
            .onChange(of: geometry.size) { _, newSize in lastKnownPanelSize = newSize }
        }
        // Fill the window so resizing keeps the same layout rules.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topLeading) {
            if (showControls || isAudioOutputMenuPresented) && musicController.currentPage == .album {
                let lum = topLeftLuminance
                MusicButtonView(artworkBrightness: lum, isAlbumPage: true)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if (showControls || isAudioOutputMenuPresented) && musicController.currentPage == .album {
                let lum = topRightLuminance
                if onExpand != nil {
                    ExpandButtonView(onExpand: onExpand!, artworkBrightness: lum, isAlbumPage: true)
                        .padding(12)
                        .transition(.opacity)
                } else {
                    AudioOutputSwitcherView(
                        artworkBrightness: lum,
                        isAlbumPage: true,
                        onMenuPresentedChanged: { presented in
                            isAudioOutputMenuPresented = presented
                            if presented { TourHookBus.shared.audioOutputMenuOpened.send(()) }
                        }
                    )
                        .padding(12)
                        .transition(.opacity)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !isHovering else { return }
                let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
                let hoverAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.82)
                let controlsAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)
                withAnimation(hoverAnim) { isHovering = true }
                controlsBlurAmount = 10
                controlsOffsetY = 30
                withAnimation(controlsAnim) {
                    showControls = true
                    showOverlayContent = true
                    controlsBlurAmount = 0
                    controlsOffsetY = 0
                }
                // Onboarding tour hook (§6 "控件出现"): the machine ignores
                // repeats of an already-resolved beat, so no local
                // "first time only" bookkeeping is needed here.
                TourHookBus.shared.controlsRevealed.send(())
            case .ended:
                if hoverLocked { return }
                let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
                let controlsAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)
                let hoverAnim: Animation = reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.82)
                withAnimation(hoverAnim) { isHovering = false }
                if isAudioOutputMenuPresented { return }
                withAnimation(controlsAnim) {
                    showOverlayContent = false
                    controlsBlurAmount = 10
                    controlsOffsetY = 30
                    showControls = false
                }
            }
        }
        // Mirror fullscreen album-cover preference changes.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newValue = UserDefaults.standard.bool(forKey: "fullscreenAlbumCover")
            if newValue != fullscreenAlbumCover {
                withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.82)) {
                    fullscreenAlbumCover = newValue
                }
                // The composite behind every button (hero vs fluid backdrop) just
                // changed — recompute icon tones for the new mode.
                refreshButtonIconTones()
            }
        }
        // Artwork changes update luminance and the smaller effect-only render image.
        .onChange(of: musicController.currentArtwork) { _, newArtwork in
            refreshEffectArtwork()
            if newArtwork != nil {
                syncArtworkLuminance()
                if let artwork = newArtwork {
                    artworkTone = ArtworkBackgroundToneMap.forMetrics(artwork.artworkVisualMetrics())
                }
            } else {
                artworkBrightness = 0.5
                topLeftLuminance = 0.5
                topRightLuminance = 0.5
                artworkTone = .neutral
            }
            refreshButtonIconTones()
        }
        .onChange(of: musicController.artworkLuminance) { _, _ in
            syncArtworkLuminance()
        }
        .onChange(of: isAudioOutputMenuPresented) { _, presented in
            guard !presented, !isHovering, musicController.currentPage == .album else { return }
            let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4
            withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)) {
                showOverlayContent = false
                controlsBlurAmount = 10
                controlsOffsetY = 30
                showControls = false
            }
        }
        .onChange(of: musicController.topLeftArtworkLuminance) { _, _ in
            syncArtworkLuminance()
        }
        .onChange(of: musicController.topRightArtworkLuminance) { _, _ in
            syncArtworkLuminance()
        }
        .onChange(of: musicController.currentPersistentID) { _, _ in
            refreshEffectArtwork()
        }
        .onChange(of: musicController.currentTrackTitle) { _, _ in
            refreshEffectArtwork()
        }
        .onChange(of: musicController.currentArtist) { _, _ in
            refreshEffectArtwork()
        }
        .onAppear {
            refreshEffectArtwork()
            syncArtworkLuminance()
            if let artwork = musicController.currentArtwork {
                artworkTone = ArtworkBackgroundToneMap.forMetrics(artwork.artworkVisualMetrics())
            }
            refreshButtonIconTones()
        }
        // Keep hover state coherent when returning to the album page.
        .onChange(of: musicController.currentPage) { oldPage, newPage in
            logPageSwitch(from: oldPage, to: newPage)
            // 从歌单/歌词页切换到专辑页时，强制同步 hover 状态
            if newPage == .playlist {
                hoverLocked = false
                showControls = false
                showOverlayContent = false
            }
            if newPage == .album && oldPage != .album {
                let animationDuration = fullscreenAlbumCover ? 0.5 : 0.4

                // 🔑 锁定 hover 状态，防止 onHover(false) 覆盖
                hoverLocked = true

                // 🔑 用 withAnimation 包裹所有状态变化，确保动画系统正确处理
                controlsBlurAmount = 10
                controlsOffsetY = 30
                withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: animationDuration, dampingFraction: 0.85)) {
                    isHovering = true
                    showControls = true
                    showOverlayContent = true
                    controlsBlurAmount = 0
                    controlsOffsetY = 0
                }

                // 🔑 延迟解除锁定（动画完成后）
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                    hoverLocked = false
                }
            }
        }
        // Onboarding tour anchors (§4.2): every `.tourAnchor(_:)` in the page
        // stack (play/pause, ↖ Music, audio output, lyrics nav, translate,
        // artwork) bubbles its screen rect up to here.
        .tourPageHooks(controlsShown: showControls, page: musicController.currentPage, reportsFor: { $0 != .lyrics })
    }

    // C2 三时钟：geometry(hero) / content(文案控件) / material(整页crossfade)
    // 三个独立 Animation，由 MicroInteractionFeel.pageSwitch 臂选择（`.split`
    // 默认三时钟拆分；`.single` 与今天字节级一致，仍是同一个
    // `.spring(response: 0.25, dampingFraction: 0.9)`）。
    private var pageSwitchAnimations: (geometry: Animation, content: Animation, material: Animation) {
        PageSwitchClockScheduler.animations(arm: MicroInteractionFeel.pageSwitch, reduceMotion: reduceMotion)
    }

    private func logPageSwitch(from: PlayerPage, to: PlayerPage) {
        let arm = MicroInteractionFeel.pageSwitch
        let plan = PageSwitchClockScheduler.plan(reduceMotion: reduceMotion)
        DebugLogger.log("PageSwitch", "t=\(CACurrentMediaTime()) arm=\(arm.rawValue) from=\(from) to=\(to) geometry=\(plan.geometryDuration) contentLag=\(plan.contentLag) material=\(plan.materialDuration)")
    }

    private func syncArtworkLuminance() {
        artworkBrightness = musicController.artworkLuminance
        topLeftLuminance = musicController.topLeftArtworkLuminance
        topRightLuminance = musicController.topRightArtworkLuminance
    }

    /// Recomputes the shuffle/repeat buttons' icon tone (founder 2026-09-24, narrowed to
    /// just these two the same day). Called once per artwork change / fullscreen-cover
    /// toggle (see the call sites above) — never per frame. `artworkTone` must already
    /// reflect the current artwork when this runs.
    ///
    /// Runs the actual composite render OFF the main thread via `buttonIconCoordinator`
    /// (2026-09-24 review: a synchronous call here would hitch every song/cover change).
    /// `refresh` returns `nil` when a newer refresh has already superseded this one — in
    /// that case `buttonIconTones` is left untouched, so the previous tones stay on
    /// screen, never cleared or flashed. A fullscreen-cover toggle goes through this exact
    /// same path, so it is not literally instant, but nothing here is throttled/debounced
    /// either — it starts immediately, same as an artwork change.
    private func refreshButtonIconTones() {
        let fullscreen = fullscreenAlbumCover
        let artwork = musicController.currentArtwork
        let tone = artworkTone
        let panelSize = lastKnownPanelSize
        let reduceTransparencySnapshot = reduceTransparency

        // Only the currently-selected arm's (expensive, fullscreen-composite-
        // rendering) pipeline runs — the other arm's @State is simply left
        // stale/unused, same as any other inactive-arm state elsewhere in this
        // codebase. Switching arms via `defaults write` mid-session picks this
        // branch up on the next natural trigger (track/cover change, fullscreen
        // toggle, panel re-appear); see research/album-buttons-2026-09-26.md.
        switch MicroInteractionFeel.buttonFill {
        case .legacy:
            let previous = buttonIconTones
            let coordinator = buttonIconCoordinator
            Task {
                guard let result = await coordinator.refresh(
                    fullscreen: fullscreen,
                    artwork: artwork,
                    tone: tone,
                    panelSize: panelSize,
                    reduceTransparency: reduceTransparencySnapshot,
                    previous: previous
                ) else { return }
                buttonIconTones = result
            }
        case .tinted:
            let previous = buttonFillColors
            let coordinator = buttonFillCoordinator
            Task {
                guard let result = await coordinator.refresh(
                    fullscreen: fullscreen,
                    artwork: artwork,
                    tone: tone,
                    panelSize: panelSize,
                    reduceTransparency: reduceTransparencySnapshot,
                    previous: previous
                ) else { return }
                buttonFillColors = result
            }
        }
    }

    /// `buttonIconTones[id]` as a `Color` — a solved neutral gray when the background is
    /// too bright, else white (today's colour, including when this button has not been
    /// resolved yet). Only reachable from `.legacy`'s render path — see `neutralIconColor`.
    private func iconColor(for id: ButtonIconID) -> Color {
        switch buttonIconTones[id] {
        case .gray(let lightness): return Color(white: lightness)
        case .white, .none: return .white
        }
    }

    /// The shuffle/repeat icon colour for its NEUTRAL (not shuffle-on/repeat-on)
    /// state, branched on the current `buttonFill` arm: `.tinted` always draws a
    /// pure white icon (the fill guarantees contrast — see `ButtonFillTint`);
    /// `.legacy` keeps today's white-or-solved-gray behaviour unchanged.
    private func neutralIconColor(for id: ButtonIconID) -> Color {
        MicroInteractionFeel.buttonFill == .tinted ? .white : iconColor(for: id)
    }

    /// `.tinted` arm's fill `Color` for one button — `ButtonFillTint`'s resolved
    /// colour once available, else a neutral mid-gray placeholder before the
    /// first async resolve lands (matches `ButtonFillTint`'s own darkened range,
    /// so there is no bright flash before the real colour arrives).
    private func fillColor(for id: ButtonIconID) -> Color {
        let rgb = buttonFillColors[id] ?? BackdropLegibilityBand.RGBColor(r: 0.35, g: 0.35, b: 0.35)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private func refreshEffectArtwork() {
        let signature = ArtworkDisplayImageFactory.signature(
            for: musicController.currentArtwork,
            trackID: musicController.currentPersistentID,
            title: musicController.currentTrackTitle,
            artist: musicController.currentArtist
        )
        guard signature != effectArtworkSignature else { return }
        effectArtworkSignature = signature

        guard let artwork = musicController.currentArtwork else {
            effectArtwork = nil
            return
        }

        effectArtwork = ArtworkDisplayImageFactory.makeEffectArtwork(from: artwork)
    }
}

// MARK: - MiniPlayerView Methods
extension MiniPlayerView {
    // MARK: - Album Overlay Content (文字遮罩 + 底部控件)
    @ViewBuilder
    func albumOverlayContent(geometry: GeometryProxy) -> some View {
        GeometryReader { geo in
            // 🔑 全屏模式：封面尺寸始终为窗口宽度；普通模式：根据hover状态变化
            let artSize = fullscreenAlbumCover ? geo.size.width : (isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68)
            // 控件区域高度（与SharedBottomControls一致）
            let controlsHeight: CGFloat = 80
            // 🔑 非全屏模式：非hover时封面在整个窗口居中，hover时在可用区域居中
            let availableHeight = isHovering ? (geo.size.height - controlsHeight) : geo.size.height
            let artCenterY = availableHeight / 2
            let artBottomY = artCenterY + artSize / 2
            // 🔑 非全屏模式：封面左边缘 X 位置
            let artLeftX = (geo.size.width - artSize) / 2

            ZStack {
                // ═══════════════════════════════════════════
                // 🎨 歌曲信息：使用 matchedGeometryEffect 实现丝滑过渡
                // ═══════════════════════════════════════════

                // 🔑 标题 - matchedGeometryEffect
                Text(musicController.currentTrackTitle)
                    .font(.system(size: isHovering ? 12 : 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3 + 0.5 * artworkBrightness), radius: 4 + 12 * artworkBrightness, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.15 + 0.25 * artworkBrightness), radius: 2 + 4 * artworkBrightness, x: 0, y: 0)
                    .modifier(SkipTextTransition(
                        text: musicController.currentTrackTitle,
                        direction: musicController.skipDirection
                    ))
                    .matchedGeometryEffect(id: "trackTitle", in: animation)
                    .frame(width: isHovering ? geo.size.width - 112 : artSize - 24, alignment: .leading)
                    .position(
                        x: isHovering
                            ? 32 + (geo.size.width - 112) / 2  // hover: 左边距32，右边距80
                            : (fullscreenAlbumCover
                                ? 12 + (geo.size.width - 24) / 2  // 全屏: 左边距12
                                : artLeftX + 12 + (artSize - 24) / 2),  // 普通: 封面内左边距12
                        y: isHovering
                            ? geo.size.height - controlsHeight - 4 - 16  // hover: 控件上方
                            : (fullscreenAlbumCover
                                ? geo.size.height - 12 - 18 - 8  // 全屏非hover: 底边距12 + 艺术家行高18 + 间距8
                                : artBottomY - 38)   // 普通: 封面底部内，标题位置（距底边38）
                    )
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)

                // 🔑 艺术家 - matchedGeometryEffect
                Text(musicController.currentArtist)
                    .font(.system(size: isHovering ? 10 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering ? 0.7 : 0.9))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3 + 0.5 * artworkBrightness), radius: 4 + 12 * artworkBrightness, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.15 + 0.25 * artworkBrightness), radius: 2 + 4 * artworkBrightness, x: 0, y: 0)
                    .modifier(SkipTextTransition(
                        text: musicController.currentArtist,
                        direction: musicController.skipDirection,
                        offset: 22,
                        maxBlur: 6
                    ))
                    .matchedGeometryEffect(id: "artistName", in: animation)
                    .frame(width: isHovering ? geo.size.width - 112 : artSize - 24, alignment: .leading)
                    .position(
                        x: isHovering
                            ? 32 + (geo.size.width - 112) / 2  // hover: 左边距32，右边距80
                            : (fullscreenAlbumCover
                                ? 12 + (geo.size.width - 24) / 2  // 全屏: 左边距12
                                : artLeftX + 12 + (artSize - 24) / 2),  // 普通: 封面内左边距12
                        y: isHovering
                            ? geo.size.height - controlsHeight - 4 - 4   // hover: 标题下方
                            : (fullscreenAlbumCover
                                ? geo.size.height - 12 - 8  // 全屏非hover: 底边距12 + 半行高8（艺术家在最下方）
                                : artBottomY - 18)   // 普通: 封面底部内，艺术家位置（距底边18）
                    )
                    .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
                    .allowsHitTesting(false)

                // ═══════════════════════════════════════════
                // 🎨 hover 状态：底部控件（blur+move-in 动画）
                // ═══════════════════════════════════════════
                VStack(spacing: 0) {
                    Spacer()

                    // 🔑 Shuffle/Repeat 按钮行
                    HStack {
                        Spacer()
                        shuffleRepeatCluster
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 4)
                    .blur(radius: controlsBlurAmount)
                    .offset(y: controlsOffsetY)

                    // 🔑 SharedBottomControls
                    SharedBottomControls(
                        timePublisher: musicController.timePublisher,
                        currentPage: $musicController.currentPage,
                        isHovering: $isHovering,
                        showControls: $showControls,
                        isProgressBarHovering: $isProgressBarHovering,
                        dragPosition: $dragPosition
                    )
                    .blur(radius: controlsBlurAmount)
                    // The tour points at where these controls REST, not at the
                    // spot they slide in from while the panel is not hovered.
                    .tourControlsSlide(offsetY: controlsOffsetY)
                }
                .opacity(showOverlayContent ? 1 : 0)
                .allowsHitTesting(showOverlayContent)
                // Short cross-fade when shuffle/repeat's icon tone changes (founder
                // 2026-09-24) — never a hard snap.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: buttonIconTones)
                // Same short cross-fade for the `.tinted` arm's fill colour changes
                // (buttonIconTones itself never changes on that arm, so it alone
                // would not animate this transition).
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: buttonFillColors)
            }
            // 🔑 动画时长：全屏模式 0.5s，非全屏模式 0.4s
            .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: isHovering)
            .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: fullscreenAlbumCover ? 0.5 : 0.4, dampingFraction: 0.85), value: showOverlayContent)
        }
    }

    // MARK: - Shuffle/Repeat Cluster (round circles on album page)
    @ViewBuilder
    private var shuffleRepeatCluster: some View {
        let themeColor = Color(red: 0.99, green: 0.24, blue: 0.27)
        let fillArm = MicroInteractionFeel.buttonFill
        let prefersSolidFill = reduceTransparency || colorSchemeContrast == .increased

        HStack(spacing: 4) {
            Button(action: { musicController.toggleShuffle() }) {
                AnimatedShuffleIcon(
                    color: musicController.shuffleEnabled ? themeColor : neutralIconColor(for: .shuffle),
                    isEnabled: musicController.shuffleEnabled
                )
                .frame(width: 24, height: 24)
                .modifier(ShuffleRepeatCircleChrome(
                    isEnabled: musicController.shuffleEnabled,
                    themeColor: themeColor,
                    fillColor: fillColor(for: .shuffle),
                    fillArm: fillArm,
                    prefersSolidFill: prefersSolidFill
                ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("随机播放")
            .accessibilityAddTraits(musicController.shuffleEnabled ? .isSelected : [])

            Button(action: { musicController.cycleRepeatMode() }) {
                Image(systemName: musicController.repeatMode == 1 ? "repeat.1" : "repeat")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(musicController.repeatMode > 0 ? themeColor : neutralIconColor(for: .repeatButton))
                    .rotationEffect(.degrees(repeatFlow * 10))
                    .scaleEffect(1 - repeatFlow * 0.1)
                    .frame(width: 24, height: 24)
                    .modifier(ShuffleRepeatCircleChrome(
                        isEnabled: musicController.repeatMode > 0,
                        themeColor: themeColor,
                        fillColor: fillColor(for: .repeatButton),
                        fillArm: fillArm,
                        prefersSolidFill: prefersSolidFill
                    ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(musicController.repeatMode == 0 ? "关闭循环" : musicController.repeatMode == 1 ? "单曲循环" : "列表循环")
            .onChange(of: musicController.repeatMode) { _, _ in
                guard !reduceMotion else { return }
                let style = ShuffleRepeatStyle.resolve(arm: MicroInteractionFeel.shuffleRepeat, reduceMotion: reduceMotion)
                withAnimation(style.trigger) { repeatFlow = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(style.rebound) { repeatFlow = 0 }
                }
            }
        }
    }

    // MARK: - Floating Artwork
    @ViewBuilder
    private func floatingArtwork(artwork: NSImage, effectArtwork: NSImage, geometry: GeometryProxy) -> some View {
        // Use one hero image for matched movement; blurred/effect layers use a smaller render image.
        GeometryReader { geo in
            let controlsHeight: CGFloat = 80
            let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)

            let (artSize, cornerRadius, shadowRadius, xPosition, yPosition): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = {
                if musicController.currentPage == .album {
                    if fullscreenAlbumCover {
                        let size = geo.size.width
                        return (
                            size,
                            0.0,
                            0.0,
                            geo.size.width / 2,
                            size / 2
                        )
                    } else {
                        let size = isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68
                        return (
                            size,
                            12.0,
                            25.0,
                            geo.size.width / 2,
                            availableHeight / 2
                        )
                    }
                } else if musicController.currentPage == .playlist {
                    let size = min(geo.size.width * 0.18, 60.0)

                    let headerHeight: CGFloat = 36
                    let cardTopPadding: CGFloat = 8
                    let cardInnerPadding: CGFloat = 12
                    let topOffset = headerHeight + cardTopPadding + cardInnerPadding + size/2

                    let xOffset = 12 + 12 + size/2

                    return (
                        size,
                        6.0,
                        3.0,
                        xOffset,
                        topOffset
                    )
                } else {
                    // Lyrics页面：不显示
                    return (0, 0, 0, 0, 0)
                }
            }()

            if musicController.currentPage != .lyrics {
                if fullscreenAlbumCover {
                    let coverSize = geo.size.width
                    let blendHeight: CGFloat = 100

                    let isAlbumPage = musicController.currentPage == .album
                    let displaySize = isAlbumPage ? coverSize : artSize
                    let displayCornerRadius: CGFloat = isAlbumPage ? 0 : cornerRadius
                    let displayX = isAlbumPage ? geo.size.width / 2 : xPosition
                    let displayY = isAlbumPage ? coverSize / 2 : yPosition

                    let animatedBlendHeight: CGFloat = isAlbumPage ? blendHeight : 0

                    // Layer 1: blurred full-window backing image.
                    Image(nsImage: effectArtwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 50, opaque: true)
                        .saturation(artworkTone.textureSaturation)
                        .contrast(artworkTone.textureContrast)
                        .brightness(artworkTone.textureBrightness)
                        .overlay(Color.black.opacity(artworkTone.textureDimmingOpacity))
                        .opacity(isAlbumPage ? 1 : 0)
                        .accessibilityHidden(true)

                    // Layer 2: clear hero cover participating in matchedGeometryEffect.
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: displaySize, height: displaySize)
                        .clipped()
                        .mask(
                            VStack(spacing: 0) {
                                Rectangle().fill(Color.black)
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: animatedBlendHeight)
                            }
                        )
                        .cornerRadius(displayCornerRadius)
                        .shadow(
                            color: .black.opacity(isAlbumPage ? 0 : 0.5),
                            radius: isAlbumPage ? 0 : shadowRadius,
                            x: 0,
                            y: isAlbumPage ? 0 : 2
                        )
                        .matchedGeometryEffect(
                            id: isAlbumPage ? "album-placeholder" : "playlist-placeholder",
                            in: animation,
                            isSource: false
                        )
                        .position(x: displayX, y: displayY)
                        .allowsHitTesting(false)
                        .accessibilityLabel("专辑封面")
                } else {
                    ZStack {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: artSize, height: artSize)
                            .clipped()
                            .accessibilityLabel("专辑封面")

                        // Bottom progressive blur.
                        Group {
                            progressiveBlurLayer(artwork: effectArtwork, size: artSize, expand: 24, blurRadius: 8, fadeStart: 0.82, fadeEnd: 0.92)
                            progressiveBlurLayer(artwork: effectArtwork, size: artSize, expand: 16, blurRadius: 5, fadeStart: 0.77, fadeEnd: 0.87)
                            progressiveBlurLayer(artwork: effectArtwork, size: artSize, expand: 8, blurRadius: 2, fadeStart: 0.72, fadeEnd: 0.82)
                        }
                        .opacity(musicController.currentPage == .album && !isHovering ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: isHovering)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .cornerRadius(cornerRadius)
                    .shadow(
                        color: .black.opacity(0.5),
                        radius: shadowRadius,
                        x: 0,
                        y: musicController.currentPage == .album ? 12 : 2
                    )
                    .matchedGeometryEffect(
                        id: musicController.currentPage == .album ? "album-placeholder" : "playlist-placeholder",
                        in: animation,
                        isSource: false
                    )
                    .position(x: xPosition, y: yPosition)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - 渐进模糊层（消除 3 层重复代码）
    @ViewBuilder
    private func progressiveBlurLayer(artwork: NSImage, size: CGFloat, expand: CGFloat, blurRadius: CGFloat, fadeStart: Double, fadeEnd: Double) -> some View {
        Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: size + expand, height: size + expand)
            .blur(radius: blurRadius)
            .frame(width: size, height: size)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: fadeStart),
                        .init(color: .black, location: fadeEnd),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    // MARK: - Album Page Content (抽取为函数支持matchedGeometryEffect)
    @ViewBuilder
    private func albumPageContent(geometry: GeometryProxy) -> some View {
        if musicController.currentArtwork != nil {
            GeometryReader { geo in
                // 控件区域高度（与albumOverlayContent一致）
                let controlsHeight: CGFloat = 80
                // 封面可用高度
                let availableHeight = geo.size.height - (showControls ? controlsHeight : 0)
                // 🔑 全屏模式：封面尺寸始终为窗口宽度；普通模式：根据hover状态变化
                let artSize = fullscreenAlbumCover ? geo.size.width : (isHovering ? geo.size.width * 0.48 : geo.size.width * 0.68)
                // 🔑 全屏模式：顶部对齐；普通模式：垂直居中
                let artCenterY = fullscreenAlbumCover ? artSize / 2 : availableHeight / 2

                // Album Artwork Placeholder (用于matchedGeometryEffect)
                Color.clear
                    .frame(width: artSize, height: artSize)
                    .cornerRadius(fullscreenAlbumCover ? 0 : 12)
                    .matchedGeometryEffect(id: "album-placeholder", in: animation, isSource: true)
                    .onTapGesture {
                        // 🔑 快速但不弹性的动画
                        withAnimation(.spring(response: 0.2, dampingFraction: 1.0)) {
                            if musicController.currentPage == .album {
                                // 🔑 用户手动打开歌词页面
                                musicController.userManuallyOpenedLyrics = true
                                musicController.currentPage = .lyrics
                            } else {
                                musicController.currentPage = .album
                            }
                        }
                    }
                    .position(
                        x: geo.size.width / 2,
                        y: artCenterY
                    )
                    .tourAnchor(.artwork)
            }
        } else {
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: geometry.size.width * 0.70, height: geometry.size.width * 0.70)
                    .overlay(Text("No Art").foregroundColor(.white))
                Spacer()
            }
        }
    }
}

// MARK: - Shuffle/Repeat circle chrome (2026-09-26, MicroInteractionFeel.buttonFill)

/// The shuffle/repeat circle's background + material, branched on the button's
/// enabled (shuffle-on / repeat-on) state and the `buttonFill` arm. Selected
/// state (`isEnabled == true`, theme-red) is IDENTICAL on both arms — out of
/// this mechanism's scope, see `ButtonIconLegibility.swift`'s own doc comment.
/// `.legacy`'s neutral state is byte-identical to the pre-2026-09-26 shuffleRepeatCluster
/// (`Circle().fill(.clear)` + `GlassButtonTexture`). `.tinted`'s neutral state uses
/// `fillColor` (`ButtonFillTint`'s resolved colour — see ButtonFillTint.swift) via a
/// macOS 26 tinted regular glass effect (same `.glassEffect(.regular.tint(_:), in:)`
/// recipe `GlassCircle` in HoverableButtons.swift already established elsewhere in
/// this codebase, wrapped in the same `GlassEffectContainer` `GlassButtonTexture` uses
/// for these exact buttons today), a material+overlay approximation pre-26, or —
/// respecting Reduce Transparency / Increase Contrast — an OPAQUE circle in the same
/// colour instead of any translucent material (mirrors `AudioOutputPanelGlass`'s
/// existing `reduceTransparency` branch in AudioOutputSwitcherView.swift).
private struct ShuffleRepeatCircleChrome: ViewModifier {
    let isEnabled: Bool
    let themeColor: Color
    let fillColor: Color
    let fillArm: MicroInteractionFeel.ButtonFillMode
    let prefersSolidFill: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(Circle().fill(themeColor.opacity(0.2)))
                .modifier(GlassButtonTexture(shape: Circle()))
        } else if fillArm == .legacy {
            content
                .background(Circle().fill(Color.clear))
                .modifier(GlassButtonTexture(shape: Circle()))
        } else if prefersSolidFill {
            content.background(Circle().fill(fillColor))
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                content.glassEffect(.regular.tint(fillColor), in: .circle)
            }
        } else {
            content.background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .light)
                    .overlay(Circle().fill(fillColor.opacity(0.55)))
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            )
        }
    }
}

#if DEBUG
struct MiniPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            // Simulate Desktop Wallpaper (Purple)
            if let wallpaperURL = Bundle.module.url(forResource: "wallpaper", withExtension: "jpg"),
               let wallpaper = NSImage(contentsOf: wallpaperURL) {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            } else {
                Color.purple
                    .ignoresSafeArea()
            }

            // The Player Window
            MiniPlayerView()
                .environmentObject({
                    let controller = MusicController(preview: true)
                    controller.currentTrackTitle = "Cariño"
                    controller.currentArtist = "The Marías"
                    if let artURL = Bundle.module.url(forResource: "album_cover", withExtension: "jpg"),
                       let art = NSImage(contentsOf: artURL) {
                        controller.currentArtwork = art
                    }
                    return controller
                }())
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 20)
        }
    }
}
#endif
