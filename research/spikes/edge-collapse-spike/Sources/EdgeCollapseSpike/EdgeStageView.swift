/**
 * [INPUT]: EdgeCollapsePose per frame (from EdgeCollapseAppModel.tick),
 *          MusicController.shared (artwork, progress, play state).
 * [OUTPUT]: EdgeStageView — the whole edge composition as AppKit views and
 *           Core Animation layers, updated per frame by setting layer
 *           properties only.
 * [POS]: Spike v14 (2026-09-22) render layer; replaces the SwiftUI root.
 * [PROTOCOL]: Measured cause of the hitches the founder kept seeing: with a
 *   SwiftUI root, every frame re-diffed the whole view tree onto its layers
 *   (~60% of main-thread time) and redrew the liquid and the light on the
 *   main thread into freshly allocated surfaces, waiting on the render
 *   server (~25%): 7-14ms per frame against an 8.3ms budget, so frames were
 *   missed at the moments something appeared (the frame timer had measured
 *   callback spacing, not display deadlines, and hid it). Here, per frame:
 *   - the liquid is a CAShapeLayer path (drawn by the render server) masking
 *     a CAGradientLayer (black, thinning into the edge-side gradient);
 *   - glass is an NSGlassEffectView: frame, corner radius and alpha only;
 *   - the real panel and the capsule's content are SwiftUI hosting views
 *     that never re-render: only their clipping container's frame, corner
 *     radius and alpha change;
 *   - the cover is a CALayer; the progress light is CAShapeLayers.
 *   All property changes run inside a CATransaction with actions disabled.
 */

import AppKit
import SwiftUI
import Combine
import QuartzCore
import MusicMiniPlayerCore

// MARK: - SwiftUI content that does not animate per frame

/// The real nanoPod panel at its own size.
struct PanelRootView: View {
    @StateObject private var edgePresentation = EdgePresentationModel()
    var body: some View {
        let r = EdgeCollapsePoses.cardRect
        MiniPlayerView()
            .environmentObject(MusicController.shared)
            .environmentObject(edgePresentation)
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: EdgeCollapseTokens.cardCornerRadius, style: .continuous))
    }
}

/// Title, artist and the two buttons inside the capsule (layout fixed at
/// the capsule's resting size; the capsule's clip reveals it).
struct CapsuleContentView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    @ObservedObject var music = MusicController.shared

    var body: some View {
        let t = EdgeCollapseTokens.self
        VStack(spacing: 0) {
            Color.clear.frame(height: t.capsulePadding + t.capsuleArtwork + 8)
            VStack(spacing: 2) {
                Text(model.trackTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(music.currentArtist).font(.system(size: 10)).opacity(0.72).lineLimit(1)
            }
            .frame(height: t.capsuleTextHeight)
            .padding(.horizontal, 10)
            Color.clear.frame(height: 4)
            HStack(spacing: 16) { controlButtons(ink: .white) }
                .frame(height: t.capsuleControlsHeight)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: t.capsuleSize.width, height: t.capsuleSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.requestExpand() }
    }

    /// Pause/play inside a progress ring; next without a ring; same visual size.
    @ViewBuilder
    private func controlButtons(ink: Color) -> some View {
        let ring: CGFloat = 30, stroke: CGFloat = 2.2
        ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: stroke)
            Circle().trim(from: 0, to: progress)
                .stroke(ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            PlayPauseControlButton(isPlaying: music.isPlaying, inkColor: ink, hoverFill: ink.opacity(0.18)) {
                music.togglePlayPause()
            }
            .scaleEffect(0.72)
        }
        .frame(width: ring, height: ring)
        SkipControlButton(action: { music.nextTrack() }, direction: 1, inkColor: ink, hoverFill: ink.opacity(0.18))
            .scaleEffect(1.15)
            .frame(width: 34, height: ring)
    }

    private var progress: CGFloat {
        guard music.duration > 0 else { return 0 }
        return CGFloat(min(max(music.currentTime / music.duration, 0), 1))
    }
}

/// The panel's hosting view also reports two-finger scrolls (its own
/// scroll views would otherwise swallow them before the stage sees them).
final class PanelHostingView: NSHostingView<PanelRootView> {
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
        super.scrollWheel(with: event)
    }
}

/// Top-left origin, like the poses.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A full-bounds container that is transparent to clicks itself; only its
/// content receives them.
final class PassThroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

// MARK: - The stage

final class EdgeStageView: NSView {
    override var isFlipped: Bool { true }

    // Gesture plumbing (same contract as the old hosting view).
    enum SwipePhase { case began, changed(dx: CGFloat, dy: CGFloat), ended }
    var onSwipe: ((SwipePhase) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onTapLiquid: (() -> Void)?
    var activeHitRegionProvider: (() -> CGRect)?
    private var trackingArea: NSTrackingArea?

    // Layers and views, back to front.
    /// NSGlassEffectView (macOS 26; the spike only runs there).
    private let glass: NSView = {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .clear
            return g
        }
        return NSView()
    }()
    private let liquidFill = CAGradientLayer()
    private let liquidMask = CAShapeLayer()
    private let panelShadow = CALayer()
    /// Full-bounds containers that never move; a CAShapeLayer mask (render
    /// server) does the clipping. Moving the hosting views per frame made
    /// AppKit lay out and SwiftUI redraw them every frame, blocking on the
    /// render server (sampled: 63% of main-thread time).
    private let panelClip = PassThroughView()
    private let panelMask = CAShapeLayer()
    private let capsuleMask = CAShapeLayer()
    let panelHost: PanelHostingView
    private let heroLayer = CALayer()
    private let capsuleClip = PassThroughView()
    private let capsuleHost: NSHostingView<CapsuleContentView>
    private let rimTrack = CAShapeLayer()
    private let rimHalo = CAShapeLayer()
    private let rimLit = CAShapeLayer()
    /// A clear Liquid Glass lens riding on the progress head (founder's
    /// reference: a glass knob magnifying the bar under it).
    private let rimKnob: NSView = {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .clear
            return g
        }
        return NSView()
    }()

    private var lastPose: EdgeCollapsePose?
    private var glowColor = NSColor.controlAccentColor
    private var hoverBoost: CGFloat = 0
    private var contentBlurApplied: CGFloat = -1
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: Timer?

    init(model: EdgeCollapseAppModel) {
        panelHost = PanelHostingView(rootView: PanelRootView())
        capsuleHost = NSHostingView(rootView: CapsuleContentView(model: model))
        super.init(frame: NSRect(origin: .zero, size: EdgeCollapseTokens.containerSize))
        wantsLayer = true
        layer?.masksToBounds = true

        let env = ProcessInfo.processInfo.environment
        if env["ECS_AB_NO_GLASS"] == nil { addSubview(glass) }

        liquidFill.frame = bounds
        liquidFill.mask = liquidMask
        liquidMask.frame = bounds
        liquidMask.fillColor = NSColor.black.cgColor
        let fillView = FlippedView(frame: bounds)
        fillView.wantsLayer = true
        fillView.layer?.addSublayer(liquidFill)
        addSubview(fillView)

        let shadowView = FlippedView(frame: bounds)
        shadowView.wantsLayer = true
        panelShadow.shadowColor = NSColor.black.cgColor
        panelShadow.shadowRadius = 18
        panelShadow.shadowOffset = CGSize(width: 0, height: 8)
        panelShadow.shadowOpacity = 0
        shadowView.layer?.addSublayer(panelShadow)
        addSubview(shadowView)

        panelClip.frame = bounds
        panelClip.wantsLayer = true
        panelClip.layer?.mask = panelMask
        panelMask.frame = bounds
        panelHost.sizingOptions = []
        panelHost.frame = EdgeCollapsePoses.cardRect
        panelClip.addSubview(panelHost)
        if env["ECS_AB_NO_PANEL"] == nil { addSubview(panelClip) }

        let heroView = FlippedView(frame: bounds)
        heroView.wantsLayer = true
        heroLayer.masksToBounds = true
        heroLayer.cornerCurve = .continuous
        heroLayer.contentsGravity = .resizeAspectFill
        heroView.layer?.addSublayer(heroLayer)
        addSubview(heroView)

        capsuleClip.frame = bounds
        capsuleClip.wantsLayer = true
        capsuleClip.layer?.mask = capsuleMask
        capsuleMask.frame = bounds
        capsuleHost.sizingOptions = []
        capsuleHost.frame = EdgeCollapsePoses.capsuleRect
        capsuleClip.addSubview(capsuleHost)
        if env["ECS_AB_NO_CAPSULE"] == nil { addSubview(capsuleClip) }

        let rimView = FlippedView(frame: bounds)
        rimView.wantsLayer = true
        for l in [rimTrack, rimHalo, rimLit] {
            l.frame = bounds
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            rimView.layer?.addSublayer(l)
        }
        rimTrack.lineWidth = 2.5
        rimHalo.lineWidth = 7
        rimLit.lineWidth = 2.5
        if env["ECS_AB_NO_RIM"] == nil {
            addSubview(rimView)
            addSubview(rimKnob)
        }

        let music = MusicController.shared
        music.$currentArtwork.receive(on: DispatchQueue.main).sink { [weak self] img in
            self?.heroLayer.contents = img.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }.store(in: &cancellables)
        music.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshLight() }.store(in: &cancellables)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLight() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Per-frame update

    func apply(_ p: EdgeCollapsePose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        lastPose = p
        let t = EdgeCollapseTokens.self
        let parts = EdgeCollapsePoses.liquidParts(p)

        // Liquid outline + fill (black, thinning into the edge gradient).
        liquidMask.path = LiquidOutline.path(parts: parts, neck: t.liquidNeck).cgPath
        let g = CGFloat(min(max(p.glass, 0), 1))
        let box = parts.filter { $0.rect.width >= 1 && $0.rect.height >= 1 }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        if !box.isNull {
            liquidFill.startPoint = CGPoint(x: box.minX / bounds.width, y: 0.5)
            liquidFill.endPoint = CGPoint(x: min(box.maxX, bounds.width) / bounds.width, y: 0.5)
        }
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * g }
        liquidFill.colors = [NSColor.black.withAlphaComponent(lerp(1, t.edgeDimInnerOpacity)).cgColor,
                             NSColor.black.withAlphaComponent(lerp(1, t.edgeDimMidOpacity)).cgColor,
                             NSColor.black.withAlphaComponent(lerp(1, t.edgeDimOpacity)).cgColor]
        liquidFill.locations = [0, 0.5, 1]

        // Glass: the larger visible part, as a rounded rect (only shown when
        // the object is one rounded shape: capsule or card).
        let clip = largerPart(p)
        glass.frame = clip.rect
        if #available(macOS 26.0, *) { (glass as? NSGlassEffectView)?.cornerRadius = clip.corner }
        glass.alphaValue = g
        glass.isHidden = g < 0.01

        // The real panel: never moves; clipped to the liquid's visible part.
        let card = EdgeCollapsePoses.cardRect
        panelMask.path = CGPath(roundedRect: clip.rect, cornerWidth: max(clip.corner, 0), cornerHeight: max(clip.corner, 0), transform: nil)
        let panel = CGFloat(min(max(p.panelOpacity, 0), 1))
        panelClip.alphaValue = panel
        panelClip.isHidden = panel < 0.005
        setPanelAttached(panel > 0.001 || panelWanted)
        let atRest = abs(clip.rect.width - card.width) < 0.5 && abs(clip.rect.height - card.height) < 0.5
        panelShadow.frame = card
        panelShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: card.size), cornerWidth: t.cardCornerRadius,
                                        cornerHeight: t.cardCornerRadius, transform: nil)
        panelShadow.shadowOpacity = atRest && panel > 0.99 ? 0.35 : 0

        // Cover (capsule's own).
        let heroAlpha = Float(min(max(p.heroOpacity, 0), 1) * (1 - Double(panel)))
        heroLayer.frame = p.hero
        heroLayer.cornerRadius = max(p.heroCorner, 0)
        heroLayer.opacity = heroAlpha
        heroLayer.isHidden = heroAlpha < 0.005

        // Capsule content: fixed layout, revealed by the capsule's clip.
        let c = CGRect(x: p.capsule.minX, y: p.capsule.minY, width: max(p.capsule.width, 0), height: max(p.capsule.height, 0))
        let cr = min(max(p.capsuleCorner, 0), min(c.width, c.height) / 2)
        capsuleMask.path = CGPath(roundedRect: c, cornerWidth: cr, cornerHeight: cr, transform: nil)
        let content = CGFloat(min(max(p.capsuleContentOpacity, 0), 1))
        capsuleClip.alphaValue = content
        capsuleClip.isHidden = content < 0.01
        let blur = content < 0.99 ? max(p.capsuleContentBlur, 0) : 0
        if abs(blur - contentBlurApplied) > 0.25 || (blur == 0 && contentBlurApplied != 0) {
            // A fresh filter each change (a mutated CIFilter is ignored).
            capsuleHost.layer?.filters = blur > 0.25 ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])!] : nil
            contentBlurApplied = blur
        }

        updateLight(p)
    }

    /// The hidden panel kept its SwiftUI graph (lyrics renderer, timers)
    /// running every frame and competing with the animation: A/B, main-thread
    /// work per frame median 4-6ms with it vs 0.5-1.9ms without. Off-window,
    /// a hosting view stops updating; it is re-attached as an expand starts.
    var panelWanted = false { didSet { if panelWanted { setPanelAttached(true) } } }
    private func setPanelAttached(_ on: Bool) {
        if on, panelHost.superview == nil {
            panelClip.addSubview(panelHost)
        } else if !on, panelHost.superview != nil {
            panelHost.removeFromSuperview()
        }
    }

    private func largerPart(_ p: EdgeCollapsePose) -> (rect: CGRect, corner: CGFloat) {
        let b = CGRect(x: p.body.maxX - max(p.body.width, 0), y: p.body.minY, width: max(p.body.width, 0), height: p.body.height)
        let c = p.capsule
        let bodyArea = b.width * b.height, capArea = max(c.width, 0) * max(c.height, 0)
        if capArea > bodyArea { return (c, min(p.capsuleCorner, min(c.width, c.height) / 2)) }
        return (b, min(p.bodyCornerInner, min(b.width, b.height) / 2))
    }

    // MARK: Progress light around the sliver

    func setGlowColor(_ c: NSColor) { glowColor = c; refreshLight() }

    func setHoverBoost(_ on: Bool) {
        hoverBoost = on ? 1 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.12 : 0.2)
        applyLightStyle()
        CATransaction.commit()
    }

    private func refreshLight() {
        guard let p = lastPose else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLight(p)
        CATransaction.commit()
    }

    /// A thin track traced 2pt outside the sliver's three inner sides (top,
    /// inner side, bottom); the lit part = progress, from the bottom where
    /// the sliver meets the bezel, with a glowing head. Only the lit part has
    /// a halo, so it reads as a progress bar, not as a glow.
    private func updateLight(_ p: EdgeCollapsePose) {
        let t = EdgeCollapseTokens.self
        let music = MusicController.shared
        let progress = music.duration > 0 ? CGFloat(min(max(music.currentTime / music.duration, 0), 1)) : 0
        let level = Float(min(max(p.glow, 0), 1)) * (music.isPlaying ? 1 : 0.75)
        let len = CGFloat(max(p.glowLength, 0))
        let path = EdgeRimGeometry.path(sliverWidth: t.handleSize.width, height: len, edge: bounds.width, midY: bounds.height / 2)
        for l in [rimTrack, rimHalo, rimLit] { l.path = path; l.opacity = level }
        rimHalo.strokeEnd = progress
        rimLit.strokeEnd = progress
        let head = EdgeRimGeometry.point(atFraction: progress, sliverWidth: t.handleSize.width, height: len,
                                         edge: bounds.width, midY: bounds.height / 2)
        // Knob: tall on the inner side, wide on the top/bottom runs.
        let onSide = abs(head.x - (bounds.width - t.handleSize.width - EdgeRimGeometry.gap)) < 0.75
        let knob = onSide ? CGSize(width: 9, height: 14) : CGSize(width: 14, height: 9)
        rimKnob.frame = CGRect(x: head.x - knob.width / 2, y: head.y - knob.height / 2, width: knob.width, height: knob.height)
        if #available(macOS 26.0, *) { (rimKnob as? NSGlassEffectView)?.cornerRadius = min(knob.width, knob.height) / 2 }
        rimKnob.alphaValue = CGFloat(level)
        rimKnob.isHidden = level < 0.05 || len < 20
        applyLightStyle()
    }

    private func applyLightStyle() {
        let c = glowColor
        rimTrack.strokeColor = NSColor(white: 0.85, alpha: 0.45).cgColor
        rimLit.strokeColor = c.cgColor
        rimHalo.strokeColor = c.withAlphaComponent(0.14 + 0.16 * hoverBoost).cgColor
        rimHalo.lineWidth = 7 + 3 * hoverBoost
    }

    // MARK: Gestures and hit testing

    func refreshHitRegion() { updateTrackingAreas() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let rect = activeHitRegionProvider?() ?? .zero
        guard rect.width > 0, rect.height > 0 else { trackingArea = nil; return }
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let rect = activeHitRegionProvider?() ?? .zero
        guard rect.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseDown(with event: NSEvent) { onTapLiquid?() }

    override func scrollWheel(with event: NSEvent) {
        forwardSwipe(event)
        super.scrollWheel(with: event)
    }

    func forwardSwipe(_ event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        switch event.phase {
        case .began: onSwipe?(.began)
        case .changed: onSwipe?(.changed(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
        case .ended, .cancelled: onSwipe?(.ended)
        default: break
        }
    }
}

/// The progress path around the sliver: from where its bottom meets the
/// bezel, along the bottom, round the inner side, along the top, back to the
/// bezel — 2pt outside the black.
enum EdgeRimGeometry {
    static let gap: CGFloat = 2

    static func path(sliverWidth w: CGFloat, height: CGFloat, edge: CGFloat, midY: CGFloat) -> CGPath {
        let p = CGMutablePath()
        guard height > 0.5 else { return p }
        let outer = w + gap
        let h = height + gap * 2
        let r = min(outer, h / 2)
        let top = midY - h / 2, bottom = midY + h / 2, inner = edge - outer
        p.move(to: CGPoint(x: edge, y: bottom))
        p.addLine(to: CGPoint(x: inner + r, y: bottom))
        p.addArc(center: CGPoint(x: inner + r, y: bottom - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: inner, y: top + r))
        p.addArc(center: CGPoint(x: inner + r, y: top + r), radius: r, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: edge, y: top))
        return p
    }

    /// Point at a fraction of the path's length (for the glowing head).
    static func point(atFraction f: CGFloat, sliverWidth w: CGFloat, height: CGFloat, edge: CGFloat, midY: CGFloat) -> CGPoint {
        let outer = w + gap
        let h = height + gap * 2
        let r = min(outer, h / 2)
        let top = midY - h / 2, bottom = midY + h / 2, inner = edge - outer
        let straightBottom = max(outer - r, 0), arc = .pi / 2 * r, side = max(h - 2 * r, 0)
        let total = 2 * straightBottom + 2 * arc + side
        var d = min(max(f, 0), 1) * total
        if d <= straightBottom { return CGPoint(x: edge - d, y: bottom) }
        d -= straightBottom
        if d <= arc {
            let a = CGFloat.pi / 2 + d / r
            return CGPoint(x: inner + r + r * cos(a), y: bottom - r + r * sin(a))
        }
        d -= arc
        if d <= side { return CGPoint(x: inner, y: bottom - r - d) }
        d -= side
        if d <= arc {
            let a = CGFloat.pi + d / r
            return CGPoint(x: inner + r + r * cos(a), y: top + r + r * sin(a))
        }
        d -= arc
        return CGPoint(x: inner + r + d, y: top)
    }
}
