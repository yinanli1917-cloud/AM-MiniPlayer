/**
 * [INPUT]: LiquidEdgePose per frame (canonical: edge on the right), the side
 *          it is drawn on, MusicController.shared (artwork, progress, play).
 * [OUTPUT]: LiquidEdgeStageView — the liquid, glass, capsule and progress
 *           light as Core Animation layers and AppKit views, updated per
 *           frame by setting properties only; LiquidEdgeStageWindow — the
 *           transparent window it lives in, just under the panel window.
 * [POS]: Liquid edge render layer (ported from the approved prototype). The
 *        real panel is NOT here: it stays in its own window and is revealed
 *        or covered by the controller (window alpha + content mask).
 * [PROTOCOL]: Measured in the prototype (2026-09-22): a SwiftUI root that
 *   re-rendered per frame and redrew shapes into new surfaces missed display
 *   deadlines (7-14ms/frame at 120Hz). So per frame only layer properties
 *   change: the outline is a CAShapeLayer path masking a CAGradientLayer;
 *   glass is NSGlassEffectView (frame, corner, alpha); the capsule content
 *   is a hosting view that never moves, clipped by a CAShapeLayer mask; the
 *   progress light is CAShapeLayers. All inside CATransaction with actions
 *   disabled. The left edge mirrors paths and rects; text is never flipped.
 */

import AppKit
import SwiftUI
import Combine
import QuartzCore

// MARK: - Capsule content (SwiftUI, does not animate per frame)

struct LiquidEdgeCapsuleContent: View {
    @ObservedObject var music = MusicController.shared
    var onTap: () -> Void

    var body: some View {
        let t = LiquidEdgeTokens.self
        VStack(spacing: 0) {
            Color.clear.frame(height: t.capsulePadding + t.capsuleArtwork + 8)
            VStack(spacing: 2) {
                Text(music.currentTrackTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(music.currentArtist).font(.system(size: 10)).opacity(0.72).lineLimit(1)
            }
            .frame(height: t.capsuleTextHeight)
            .padding(.horizontal, 10)
            Color.clear.frame(height: 4)
            HStack(spacing: 16) { controls(ink: .white) }
                .frame(height: t.capsuleControlsHeight)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: t.capsuleSize.width, height: t.capsuleSize.height)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// Pause/play inside a progress ring; next without a ring; same visual size.
    @ViewBuilder
    private func controls(ink: Color) -> some View {
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

// MARK: - Views

class LiquidEdgeFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A full-bounds container transparent to clicks itself.
final class LiquidEdgePassThroughView: LiquidEdgeFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

final class LiquidEdgeStageWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }
}

public enum LiquidEdgeSide: Equatable, Sendable { case left, right }

final class LiquidEdgeStageView: NSView {
    override var isFlipped: Bool { true }

    // Input plumbing (set by the controller).
    enum SwipePhase { case began, changed(dx: CGFloat, dy: CGFloat), ended }
    var onSwipe: ((SwipePhase) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    var activeHitRegionProvider: (() -> CGRect)?
    private var trackingArea: NSTrackingArea?

    var side: LiquidEdgeSide = .right
    var geometry = LiquidEdgeGeometry.reference

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
    private let heroLayer = CALayer()
    private let capsuleClip = LiquidEdgePassThroughView()
    private let capsuleMask = CAShapeLayer()
    private let capsuleHost: NSHostingView<LiquidEdgeCapsuleContent>
    private let rimTrack = CAShapeLayer()
    private let rimHalo = CAShapeLayer()
    private let rimHalo2 = CAShapeLayer()
    private let rimLit = CAShapeLayer()
    private let bead = CALayer()
    private let beadGlow = CALayer()
    private let beadBody = CAGradientLayer()
    private let beadShine = CALayer()

    private var lastPose: LiquidEdgePose?
    private var glowColor = NSColor.controlAccentColor
    private var hoverBoost: CGFloat = 0
    private var contentBlurApplied: CGFloat = -1
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: Timer?

    override init(frame: NSRect) {
        var tap: (() -> Void)?
        capsuleHost = NSHostingView(rootView: LiquidEdgeCapsuleContent(onTap: { tap?() }))
        super.init(frame: frame)
        tap = { [weak self] in self?.onTap?() }
        wantsLayer = true
        layer?.masksToBounds = true

        addSubview(glass)

        let fillView = LiquidEdgeFlippedView(frame: bounds)
        fillView.autoresizingMask = [.width, .height]
        fillView.wantsLayer = true
        liquidFill.mask = liquidMask
        liquidFill.locations = [0, 0.5, 1]
        fillView.layer?.addSublayer(liquidFill)
        addSubview(fillView)

        let heroView = LiquidEdgeFlippedView(frame: bounds)
        heroView.autoresizingMask = [.width, .height]
        heroView.wantsLayer = true
        heroLayer.masksToBounds = true
        heroLayer.contentsGravity = .resizeAspectFill
        heroView.layer?.addSublayer(heroLayer)
        addSubview(heroView)

        capsuleClip.frame = bounds
        capsuleClip.autoresizingMask = [.width, .height]
        capsuleClip.wantsLayer = true
        capsuleClip.layer?.mask = capsuleMask
        capsuleHost.sizingOptions = []
        capsuleClip.addSubview(capsuleHost)
        addSubview(capsuleClip)

        let rimView = LiquidEdgeFlippedView(frame: bounds)
        rimView.autoresizingMask = [.width, .height]
        rimView.wantsLayer = true
        for l in [rimTrack, rimHalo2, rimHalo, rimLit] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            rimView.layer?.addSublayer(l)
        }
        rimTrack.lineWidth = 1.5
        rimLit.lineWidth = 1.5
        beadGlow.shadowOpacity = 1
        beadGlow.shadowRadius = 5
        beadGlow.shadowOffset = .zero
        beadBody.masksToBounds = true
        beadBody.startPoint = CGPoint(x: 0.5, y: 0)
        beadBody.endPoint = CGPoint(x: 0.5, y: 1)
        beadBody.borderWidth = 0.5
        beadShine.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        for l in [beadGlow, beadBody, beadShine] { bead.addSublayer(l) }
        rimView.layer?.addSublayer(bead)
        addSubview(rimView)

        let music = MusicController.shared
        music.$currentArtwork.receive(on: DispatchQueue.main).sink { [weak self] img in
            guard let self else { return }
            self.heroLayer.contents = img.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            self.glowColor = img.flatMap(liquidEdgeGlowColor) ?? .controlAccentColor
            self.refreshLight()
        }.store(in: &cancellables)
        music.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshLight() }.store(in: &cancellables)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLight() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { progressTimer?.invalidate() }

    override func layout() {
        super.layout()
        for l in [liquidFill, liquidMask] { l.frame = bounds }
        for l in [rimTrack, rimHalo2, rimHalo, rimLit] { l.frame = bounds }
        capsuleMask.frame = bounds
    }

    // MARK: Mirroring (left edge)

    private func m(_ r: CGRect) -> CGRect {
        side == .right ? r : CGRect(x: bounds.width - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    private func m(_ p: CGPoint) -> CGPoint { side == .right ? p : CGPoint(x: bounds.width - p.x, y: p.y) }

    private func m(_ path: CGPath) -> CGPath {
        guard side == .left else { return path }
        var t = CGAffineTransform(translationX: bounds.width, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &t) ?? path
    }

    // MARK: Per-frame update

    func apply(_ p: LiquidEdgePose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        lastPose = p
        let t = LiquidEdgeTokens.self
        let poses = LiquidEdgePoses(geometry)
        let parts = poses.liquidParts(p)

        liquidMask.path = m(LiquidOutline.path(parts: parts, neck: t.liquidNeck).cgPath)
        let g = CGFloat(min(max(p.glass, 0), 1))
        let span = poses.fillSpan(p)
        if span.maxX - span.minX > 0.5, bounds.width > 0 {
            let x0 = span.minX / bounds.width, x1 = span.maxX / bounds.width
            liquidFill.startPoint = CGPoint(x: side == .right ? x0 : 1 - x0, y: 0.5)
            liquidFill.endPoint = CGPoint(x: side == .right ? x1 : 1 - x1, y: 0.5)
        }
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * g }
        liquidFill.colors = [NSColor.black.withAlphaComponent(lerp(1, t.edgeDimInnerOpacity)).cgColor,
                             NSColor.black.withAlphaComponent(lerp(1, t.edgeDimMidOpacity)).cgColor,
                             NSColor.black.withAlphaComponent(lerp(1, t.edgeDimOpacity)).cgColor]

        // Glass: only when the object is one rounded shape (capsule or card).
        let clip = LiquidEdgeStageView.largerPart(p)
        glass.frame = m(clip.rect)
        if #available(macOS 26.0, *) { (glass as? NSGlassEffectView)?.cornerRadius = clip.corner }
        glass.alphaValue = g
        glass.isHidden = g < 0.01

        // The capsule's cover.
        let panel = CGFloat(min(max(p.panelOpacity, 0), 1))
        let heroAlpha = Float(min(max(p.heroOpacity, 0), 1) * (1 - Double(panel)))
        heroLayer.frame = m(p.hero)
        heroLayer.cornerRadius = max(p.heroCorner, 0)
        heroLayer.opacity = heroAlpha
        heroLayer.isHidden = heroAlpha < 0.005

        // Capsule content: fixed at the capsule's resting rect, clipped by it.
        capsuleHost.frame = m(poses.capsuleRect)
        let c = CGRect(x: p.capsule.minX, y: p.capsule.minY, width: max(p.capsule.width, 0), height: max(p.capsule.height, 0))
        let cr = min(max(p.capsuleCorner, 0), min(c.width, c.height) / 2)
        capsuleMask.path = CGPath(roundedRect: m(c), cornerWidth: cr, cornerHeight: cr, transform: nil)
        let content = CGFloat(min(max(p.capsuleContentOpacity, 0), 1))
        capsuleClip.alphaValue = content
        capsuleClip.isHidden = content < 0.01
        let blur = content < 0.99 ? max(p.capsuleContentBlur, 0) : 0
        if abs(blur - contentBlurApplied) > 0.25 || (blur == 0 && contentBlurApplied != 0) {
            // A fresh filter each change (a mutated attached CIFilter is ignored).
            capsuleHost.layer?.filters = blur > 0.25 ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])!] : nil
            contentBlurApplied = blur
        }

        updateLight(p)
    }

    /// The larger visible part and its corner radius (canonical coordinates).
    static func largerPart(_ p: LiquidEdgePose) -> (rect: CGRect, corner: CGFloat) {
        let b = CGRect(x: p.body.maxX - max(p.body.width, 0), y: p.body.minY, width: max(p.body.width, 0), height: p.body.height)
        let c = CGRect(x: p.capsule.minX, y: p.capsule.minY, width: max(p.capsule.width, 0), height: max(p.capsule.height, 0))
        if c.width * c.height > b.width * b.height { return (c, min(p.capsuleCorner, min(c.width, c.height) / 2)) }
        return (b, min(p.bodyCornerInner, min(b.width, b.height) / 2))
    }

    // MARK: Progress light

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

    /// The sliver's outline pushed out 1.5pt (concentric corners), lit from
    /// the bottom where it meets the bezel = progress; a soft two-layer glow
    /// on the lit part and a small rendered bead on the head.
    private func updateLight(_ p: LiquidEdgePose) {
        let t = LiquidEdgeTokens.self
        let music = MusicController.shared
        // The render clock, not `currentTime`: that stops updating while the
        // panel is ordered out (tucked).
        let progress = music.duration > 0 ? CGFloat(min(max(music.lyricRenderTime() / music.duration, 0), 1)) : 0
        let level = Float(min(max(p.glow, 0), 1)) * (music.isPlaying ? 1 : 0.75)
        let len = CGFloat(max(p.glowLength, 0))
        let midY = geometry.card.midY
        let path = m(LiquidEdgeRim.path(sliverWidth: t.sliverSize.width, height: len, edge: geometry.edgeX, midY: midY))
        for l in [rimTrack, rimHalo, rimHalo2, rimLit] { l.path = path; l.opacity = level }
        rimHalo.strokeEnd = progress
        rimHalo2.strokeEnd = progress
        rimLit.strokeEnd = progress

        let head = LiquidEdgeRim.point(atFraction: progress, sliverWidth: t.sliverSize.width, height: len,
                                       edge: geometry.edgeX, midY: midY)
        let onSide = abs(head.x - (geometry.edgeX - t.sliverSize.width - LiquidEdgeRim.gap)) < 0.75
        let knob = onSide ? CGSize(width: 5, height: 8) : CGSize(width: 8, height: 5)
        let knobRect = m(CGRect(x: head.x - knob.width / 2, y: head.y - knob.height / 2, width: knob.width, height: knob.height))
        bead.frame = knobRect
        let r = min(knob.width, knob.height) / 2
        beadGlow.frame = bead.bounds
        beadGlow.cornerRadius = r
        beadGlow.shadowPath = CGPath(roundedRect: bead.bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        beadBody.frame = bead.bounds
        beadBody.cornerRadius = r
        beadShine.frame = CGRect(x: knobRect.width * 0.25, y: 0.8, width: knobRect.width * 0.5, height: max(knobRect.height * 0.26, 1))
        beadShine.cornerRadius = beadShine.frame.height / 2
        bead.opacity = level
        bead.isHidden = level < 0.05 || len < 20
        applyLightStyle()
    }

    private func applyLightStyle() {
        let c = glowColor
        rimTrack.strokeColor = NSColor(white: 0.9, alpha: 0.28).cgColor
        rimLit.strokeColor = c.cgColor
        rimHalo.strokeColor = c.withAlphaComponent(0.22 + 0.14 * hoverBoost).cgColor
        rimHalo.lineWidth = 4 + 2 * hoverBoost
        rimHalo2.strokeColor = c.withAlphaComponent(0.08 + 0.08 * hoverBoost).cgColor
        rimHalo2.lineWidth = 9 + 3 * hoverBoost
        let light = c.blended(withFraction: 0.45, of: .white) ?? c
        let deep = c.blended(withFraction: 0.25, of: .black) ?? c
        beadBody.colors = [light.cgColor, c.cgColor, deep.cgColor]
        beadBody.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        beadGlow.backgroundColor = c.withAlphaComponent(0.01).cgColor
        beadGlow.shadowColor = c.cgColor
        beadGlow.shadowOpacity = Float(0.8 + 0.2 * hoverBoost)
    }

    // MARK: Input

    func refreshHitRegion() { updateTrackingAreas() }

    private var hitRegion: CGRect { m(activeHitRegionProvider?() ?? .zero) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let rect = hitRegion
        guard rect.width > 0, rect.height > 0 else { trackingArea = nil; return }
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard hitRegion.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseDown(with event: NSEvent) { onTap?() }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        // Canonical direction: positive = toward the screen edge.
        let dx = side == .right ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .began: onSwipe?(.began)
        case .changed: onSwipe?(.changed(dx: dx, dy: event.scrollingDeltaY))
        case .ended, .cancelled: onSwipe?(.ended)
        default: break
        }
    }
}

/// The progress path: the sliver's outline pushed out by `gap`, corners
/// concentric with the sliver's, from where its bottom meets the bezel.
enum LiquidEdgeRim {
    static let gap: CGFloat = 1.5

    private static func frame(_ w: CGFloat, _ height: CGFloat, _ edge: CGFloat, _ midY: CGFloat)
        -> (inner: CGFloat, top: CGFloat, bottom: CGFloat, rc: CGFloat, r: CGFloat) {
        let rc = min(w / 2, height / 2)
        return (edge - w, midY - height / 2, midY + height / 2, rc, rc + gap)
    }

    static func path(sliverWidth w: CGFloat, height: CGFloat, edge: CGFloat, midY: CGFloat) -> CGPath {
        let p = CGMutablePath()
        guard height > 0.5 else { return p }
        let f = frame(w, height, edge, midY)
        let cx = f.inner + f.rc
        p.move(to: CGPoint(x: edge, y: f.bottom + gap))
        p.addLine(to: CGPoint(x: cx, y: f.bottom + gap))
        p.addArc(center: CGPoint(x: cx, y: f.bottom - f.rc), radius: f.r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: f.inner - gap, y: f.top + f.rc))
        p.addArc(center: CGPoint(x: cx, y: f.top + f.rc), radius: f.r, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: edge, y: f.top - gap))
        return p
    }

    static func point(atFraction frac: CGFloat, sliverWidth w: CGFloat, height: CGFloat, edge: CGFloat, midY: CGFloat) -> CGPoint {
        let f = frame(w, height, edge, midY)
        let cx = f.inner + f.rc
        let run = max(edge - cx, 0), arc = .pi / 2 * f.r, side = max(height - 2 * f.rc, 0)
        var d = min(max(frac, 0), 1) * (2 * run + 2 * arc + side)
        if d <= run { return CGPoint(x: edge - d, y: f.bottom + gap) }
        d -= run
        if d <= arc {
            let a = CGFloat.pi / 2 + d / f.r
            return CGPoint(x: cx + f.r * cos(a), y: f.bottom - f.rc + f.r * sin(a))
        }
        d -= arc
        if d <= side { return CGPoint(x: f.inner - gap, y: f.bottom - f.rc - d) }
        d -= side
        if d <= arc {
            let a = CGFloat.pi + d / f.r
            return CGPoint(x: cx + f.r * cos(a), y: f.top + f.rc + f.r * sin(a))
        }
        d -= arc
        return CGPoint(x: cx + d, y: f.top - gap)
    }
}

/// One colour for the edge light: the most saturated, reasonably bright
/// colour of the artwork, lifted to full brightness; grey artwork -> accent.
func liquidEdgeGlowColor(_ image: NSImage) -> NSColor? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return nil }
    let step = max(1, min(w, h) / 32)
    var weight = [Double](repeating: 0, count: 12)
    var hueSum = [Double](repeating: 0, count: 12)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
                c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
                if bri > 0.2 {
                    let wgt = Double(sat * sat * bri)
                    let b = min(Int(hue * 12), 11)
                    weight[b] += wgt; hueSum[b] += Double(hue) * wgt
                }
            }
            x += step
        }
        y += step
    }
    guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.5 else {
        return .controlAccentColor
    }
    return NSColor(hue: hueSum[best] / weight[best], saturation: 0.62, brightness: 1.0, alpha: 1)
}
