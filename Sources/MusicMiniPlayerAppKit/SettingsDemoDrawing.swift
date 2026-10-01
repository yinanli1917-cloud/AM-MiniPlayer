/**
 * [INPUT]: SwiftUI Canvas/GraphicsContext; DemoFrame + per-scene frames
 *          (SettingsDemoMotion); DemoSVGPath (icon geometry); SettingsPalette (accent).
 * [OUTPUT]: Exports DemoPalette, DemoDrawing (wallpaper + scene painters on the
 *           320×180 scene canvas).
 * [POS]: The settings demo stage's PAINT layer. Paints exactly what a DemoFrame
 *        says and computes nothing about time. Everything is drawn in a Canvas
 *        (blur / mask / group opacity are Canvas operations) rather than as
 *        stacked views on purpose: SwiftUI's `.blur` on a hosted view is a
 *        render-server filter that an offscreen capture cannot see, whereas a
 *        Canvas filter renders identically on screen and in a test capture, so
 *        the frames the tests write are the frames the founder sees. Coordinates
 *        are the prototype's CSS pixels on its 320×180 scene canvas
 *        (docs/design/2026-09-29-motion-prototype/prototype.html), `em` = panel width.
 */

import SwiftUI
import AppKit

// ──────────────────────────────────────────────
// MARK: - Palette (prototype :root tokens, light / dark)
// ──────────────────────────────────────────────

struct DemoPalette {
    let w1, w2, w3, w4: Color            // wallpaper: top-left glow, bottom-right glow, base A → B (StageWallpaper.active)
    let glassLine: Color
    let menubar: Color
    let bgwin: Color
    let bgwinLine: Color
    let strip: Color
    let keyFace: Color
    let keyEdge: Color
    let keyInk: Color
    let capInk: Color
    let pageInk: Color                   // caption chip ink (prototype --fg)
    let accent: Color
    let dark: Bool

    static func make(dark: Bool) -> DemoPalette {
        func c(_ hex: UInt32, _ a: Double = 1) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: a)
        }
        let accent = DemoPalette.resolvedAccent(dark: dark)
        let look = StageWallpaper.active.look(dark: dark)
        if dark {
            return DemoPalette(
                w1: c(look.w1), w2: c(look.w2), w3: c(look.w3), w4: c(look.w4),
                glassLine: .white.opacity(0.09), menubar: c(StageChrome.menubarDark.hex, StageChrome.menubarDark.alpha),
                bgwin: c(StageChrome.bgwinDark.hex, StageChrome.bgwinDark.alpha), bgwinLine: .white.opacity(0.08), strip: .white.opacity(0.55),
                keyFace: c(0x48484E), keyEdge: c(0x1B1B1E), keyInk: c(0xF2F2F6),
                capInk: c(StageChrome.capInkDark.hex, StageChrome.capInkDark.alpha), pageInk: c(0xF5F5F7), accent: accent, dark: true)
        }
        return DemoPalette(
            w1: c(look.w1), w2: c(look.w2), w3: c(look.w3), w4: c(look.w4),
            glassLine: .black.opacity(0.07), menubar: c(StageChrome.menubarLight.hex, StageChrome.menubarLight.alpha),
            bgwin: c(StageChrome.bgwinLight.hex, StageChrome.bgwinLight.alpha), bgwinLine: .black.opacity(0.08), strip: .white.opacity(0.75),
            keyFace: c(0xFFFFFF), keyEdge: c(0xC9C9CF), keyInk: c(0x3A3A3F),
            capInk: c(StageChrome.capInkLight.hex, StageChrome.capInkLight.alpha), pageInk: c(0x1D1D1F), accent: accent, dark: false)
    }

    /// The accent as a plain sRGB colour for this appearance (the demo highlights follow
    /// the user's accent, like every other control in the settings window).
    static func resolvedAccent(dark: Bool) -> Color {
        var out = SettingsPalette.accentNS
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = SettingsPalette.accentNS.usingColorSpace(.sRGB) ?? out
        }
        return Color(nsColor: out)
    }
}

// ──────────────────────────────────────────────
// MARK: - Drawing
// ──────────────────────────────────────────────

enum DemoDrawing {

    /// The stage box (creator's decision, 2026-09-29: centred 16:9, 300×169, radius 12).
    static let stageSize = CGSize(width: 300, height: 169)
    static let stageCornerRadius: CGFloat = 12
    /// Scenes are composed on the prototype's 320×180 canvas and scaled to the stage.
    static let sceneWidth: CGFloat = 320
    static var sceneScale: CGFloat { stageSize.width / sceneWidth }
    /// 320 × 180.27: the scaled canvas covers the whole 169pt stage (180 would leave a 0.25pt strip).
    static var sceneSize: CGSize { CGSize(width: sceneWidth, height: stageSize.height / sceneScale) }

    // MARK: wallpaper

    /// Prototype `.stage` background: glow top-left (w1), glow bottom-right (w2), 160° base (w3 → w4); colours from `StageWallpaper`.
    static func drawWallpaper(_ ctx: inout GraphicsContext, size: CGSize, palette p: DemoPalette) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: cssLinear(160, in: rect, stops: [(p.w3, 0), (p.w4, 1)]))
        fillEllipticalGlow(&ctx, in: rect, cx: 0.96, cy: 1.0, rx: 0.70, ry: 1.0, color: p.w2, fadeAt: 0.72)
        fillEllipticalGlow(&ctx, in: rect, cx: 0.12, cy: 0.0, rx: 0.60, ry: 1.0, color: p.w1, fadeAt: 0.70)
    }

    // MARK: scene entry

    static func drawScene(_ frame: DemoFrame, in ctx: inout GraphicsContext, palette p: DemoPalette) {
        // Every album panel is fullscreen-look except the Fullscreen Cover scene's own (see DemoFrame.panelCover).
        let panel = frame.panelCover ?? .fullscreenLook
        switch frame {
        case .cover(let f): drawCover(f, &ctx, p)
        case .peek(let f): drawPeek(f, panel, &ctx, p)
        case .lyrics(let f): drawLyrics(f, &ctx, p)
        case .showHide(let f): drawShowHide(f, panel, &ctx, p)
        case .hideEdge(let f): drawHideEdge(f, panel, &ctx, p)
        case .login(let f): drawLogin(f, panel, &ctx, p)
        case .dock(let f): drawDock(f, &ctx, p)
        case .still(let kind): drawStill(kind, panel, &ctx, p)
        }
    }

    // MARK: - Scenes

    private static func drawCover(_ f: CoverFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p)
        drawAlbumPanel(&ctx, p, x: 105, y: 30, pw: 110, cover: f)
    }

    private static func drawPeek(_ f: PeekFrame, _ panel: CoverFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p)
        // The panel slides out through the right screen edge and fades as it goes.
        if f.panelOpacity > 0.001 {
            var c = ctx
            c.fadeGroup(f.panelOpacity)
            c.translateBy(x: f.panelOffsetX, y: 0)
            c.drawLayer { l in drawAlbumPanel(&l, p, x: 170, y: 24, pw: 104, cover: panel) }
        }
        drawEdgeStrip(&ctx, p, opacity: f.stripOpacity, offsetX: f.stripOffsetX, fillPercent: f.fillPercent, pulse: f.pulse)
        if f.cardOpacity > 0.001 {
            var c = ctx
            c.fadeGroup(f.cardOpacity)
            c.translateBy(x: f.cardOffsetX, y: 0)
            c.drawLayer { l in drawSongCard(&l, p) }
        }
    }

    private static func drawLyrics(_ f: LyricsFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        let pw: CGFloat = 214, x: CGFloat = 53, y: CGFloat = 10
        let height = pw * 2.2
        drawPanelChrome(&ctx, x: x, y: y, width: pw, height: height, radius: 0.07 * pw, glows: [],
                        background: fullscreenPageBackground) { c in
            let fs = pw * 0.07
            let lineH = fs * 1.3
            let left: CGFloat = 18
            func line(_ text: String, top: CGFloat, opacity: Double, weight: CGFloat) {
                var t = c
                t.opacity = opacity
                // CSS weight 650 sits between semibold and bold; the system font is variable, so ask for it exactly.
                let font = Font(NSFont.systemFont(ofSize: fs, weight: NSFont.Weight(weight)) as CTFont)
                let r = t.resolve(Text(text).font(font).foregroundColor(.white))
                t.draw(r, at: CGPoint(x: left, y: top + lineH / 2), anchor: .leading)
            }
            line("Down by the water", top: 6, opacity: 0.42, weight: 0)
            line("Let\u{2019}s go see the sea", top: 30, opacity: 1, weight: 0.33)
            line("Just you, just me", top: 66 + f.followingLinesOffsetY, opacity: 0.42, weight: 0)
            line("Let the tide decide", top: 94 + f.followingLinesOffsetY, opacity: 0.42, weight: 0)

            // Translation: its own line under the current one; slides down 3pt, blurs in, fades in.
            let trFS = fs * 0.88
            let trCenter = 30 + lineH + trFS * 0.15 + trFS * 1.3 / 2 - 0.25 + f.translationOffsetY
            for (text, a) in [(f.textB, f.opacityB), (f.textA, f.opacityA)] where !text.isEmpty {
                let alpha = 0.78 * a * f.s
                if alpha < 0.002 { continue }
                var t = c
                t.opacity = alpha
                if f.translationBlur > 0.01 { t.addFilter(.blur(radius: f.translationBlur)) }
                t.drawLayer { l in
                    let r = l.resolve(Text(text).font(.system(size: trFS, weight: .medium)).foregroundColor(.white))
                    l.draw(r, at: CGPoint(x: left, y: trCenter), anchor: .leading)
                }
            }
        }
    }

    private static func drawShowHide(_ f: ShowHideFrame, _ panel: CoverFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p)
        if f.showsBackgroundWindow { drawBackgroundWindow(&ctx, p, rect: CGRect(x: 160, y: 30, width: 140, height: 100)) }
        if f.panelOpacity > 0.001 {
            var c = ctx
            c.fadeGroup(f.panelOpacity)
            // The prototype's transform origin is the wrapper's top-left corner (a zero-size box).
            c.translateBy(x: 184, y: 26)
            c.scaleBy(x: f.panelScale, y: f.panelScale)
            c.translateBy(x: -184, y: -26)
            c.drawLayer { l in drawAlbumPanel(&l, p, x: 184, y: 26, pw: 92, cover: panel) }
        }
        drawKeycaps(&ctx, p, labels: f.keys, press: f.press)
    }

    private static func drawHideEdge(_ f: HideEdgeFrame, _ panel: CoverFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p)
        if f.panelOpacity > 0.001 {
            var c = ctx
            c.fadeGroup(f.panelOpacity)
            c.translateBy(x: f.panelOffsetX, y: 0)
            c.drawLayer { l in drawAlbumPanel(&l, p, x: 170, y: 24, pw: 104, cover: panel) }
        }
        drawEdgeStrip(&ctx, p, opacity: f.stripOpacity, offsetX: f.stripOffsetX, fillPercent: 62, pulse: 0)
        drawKeycaps(&ctx, p, labels: f.keys, press: f.press)
    }

    private static func drawLogin(_ f: LoginFrame, _ panel: CoverFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p, noteScale: f.noteScale, noteOpacity: f.noteOpacity)
        drawAlbumPanel(&ctx, p, x: 108, y: 34, pw: 104, cover: panel)
        ctx.fill(Path(CGRect(origin: .zero, size: CGSize(width: sceneWidth, height: sceneSize.height + 1))),
                 with: .color(.black.opacity(f.dim)))
    }

    private static func drawDock(_ f: DockFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p)
        let block: CGFloat = 18, gap: CGFloat = 5, pad: CGFloat = 6
        let presence = CGFloat(f.presence)
        let width = pad * 2 + 4 * block + 3 * gap + presence * (block + gap)
        let height: CGFloat = 26
        let center: CGFloat = 226
        let dock = CGRect(x: center - width / 2, y: sceneSize.height - 8 - height, width: width, height: height)
        let shape = Path(roundedRect: dock, cornerRadius: 9)
        ctx.fill(shape, with: .color(p.menubar))
        ctx.stroke(shape, with: .color(p.glassLine), lineWidth: 0.5)
        let y = dock.minY + (height - block) / 2
        var x = dock.minX + pad
        for i in 0..<5 {
            if i == 2 {
                // nanoPod's slot: opens up between the neighbours while the icon drops in from above.
                if presence > 0.001 {
                    var c = ctx
                    c.opacity = Double(presence)
                    drawAppIcon(&c, p, rect: CGRect(x: x, y: y + (1 - presence) * -36, width: block, height: block))
                }
                x += presence * (block + gap)
            } else {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: block, height: block), cornerRadius: 5),
                         with: .color(p.capInk.opacity(0.5)))
                x += block + gap
            }
        }
    }

    private static func drawStill(_ kind: DemoStillKind, _ panel: CoverFrame, _ ctx: inout GraphicsContext, _ p: DemoPalette) {
        drawMenuBar(&ctx, p)
        switch kind {
        case .tour:
            drawAlbumPanel(&ctx, p, x: 64, y: 26, pw: 104, cover: panel)
            let card = CGRect(x: 172, y: 58, width: 92, height: 62)
            drawGlassCard(&ctx, p, rect: card, radius: 11)
            let ringCenter = CGPoint(x: card.minX + 24, y: card.minY + 22)
            let track = Path(ellipseIn: CGRect(x: ringCenter.x - 11.25, y: ringCenter.y - 11.25, width: 22.5, height: 22.5))
            ctx.stroke(track, with: .color(p.accent.opacity(p.dark ? 0.30 : 0.22)), lineWidth: 5.5)
            var arc = Path()
            arc.addArc(center: ringCenter, radius: 11.25, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * 3 / 7), clockwise: false)
            ctx.stroke(arc, with: .color(p.accent), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
            ctx.fill(Path(roundedRect: CGRect(x: card.minX + 44, y: card.minY + 16, width: 34, height: 4), cornerRadius: 2), with: .color(p.capInk))
            ctx.fill(Path(roundedRect: CGRect(x: card.minX + 44, y: card.minY + 25, width: 24, height: 3), cornerRadius: 1.5), with: .color(p.capInk.opacity(0.6)))
            ctx.fill(Path(roundedRect: CGRect(x: card.minX + 12, y: card.minY + 44, width: 60, height: 3), cornerRadius: 1.5), with: .color(p.capInk.opacity(0.4)))
        case .automation:
            drawAppIcon(&ctx, p, rect: CGRect(x: 56, y: 68, width: 34, height: 34))
            var link = Path()
            link.move(to: CGPoint(x: 98, y: 85)); link.addLine(to: CGPoint(x: 150, y: 85))
            ctx.stroke(link, with: .color(p.capInk), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [1, 4]))
            var chevron = Path()
            chevron.move(to: CGPoint(x: 150, y: 80)); chevron.addLine(to: CGPoint(x: 156, y: 85)); chevron.addLine(to: CGPoint(x: 150, y: 90))
            ctx.stroke(chevron, with: .color(p.capInk), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            drawAlbumPanel(&ctx, p, x: 176, y: 34, pw: 88, cover: panel)
        case .appleMusic:
            drawAlbumPanel(&ctx, p, x: 108, y: 26, pw: 104, cover: panel)
        case .history:
            drawHistoryPanel(&ctx, p, x: 108, y: 26, pw: 104)
        }
    }

    // MARK: - Shared parts

    /// Prototype `.menubar`: 12pt, translucent, hairline below; Apple mark, five menu blocks,
    /// then (right to left) time, control centre, battery, Wi-Fi, the accent-coloured nanoPod note.
    static func drawMenuBar(_ ctx: inout GraphicsContext, _ p: DemoPalette, noteScale: Double = 1, noteOpacity: Double = 1) {
        let barRect = CGRect(x: 0, y: 0, width: sceneWidth, height: 12)
        ctx.fill(Path(barRect), with: .color(p.menubar))
        ctx.fill(Path(CGRect(x: 0, y: 12, width: sceneWidth, height: 0.5)), with: .color(p.glassLine))
        let ink = p.capInk

        // Apple mark: viewBox 12×14 in a 6×7 box.
        do {
            var c = ctx
            c.opacity = 0.85
            c.translateBy(x: 9, y: 2.5)
            c.scaleBy(x: 0.5, y: 0.5)
            c.fill(DemoSVGPath.path(appleGlyph), with: .color(ink))
        }
        // Menu titles.
        var x: CGFloat = 9 + 6 + 6
        for (i, w) in [15, 9, 11, 9, 12].enumerated() {
            let r = CGRect(x: x, y: 4.5, width: CGFloat(w), height: 3)
            var c = ctx
            c.opacity = i == 0 ? 0.75 : 0.42
            c.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(ink))
            x += CGFloat(w) + 5
        }
        // Clock.
        do {
            var c = ctx
            c.opacity = 0.55
            c.fill(Path(roundedRect: CGRect(x: 296, y: 4.5, width: 16, height: 3), cornerRadius: 1.5), with: .color(ink))
        }
        // Control centre (viewBox 10×8 in 8×6.5, meet → scale 0.8).
        do {
            var c = ctx
            c.opacity = 0.62
            c.translateBy(x: 281, y: 2.8)
            c.scaleBy(x: 0.8, y: 0.8)
            c.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 10, height: 3.2), cornerRadius: 1.6), with: .color(ink))
            c.fill(Path(roundedRect: CGRect(x: 0, y: 4.8, width: 10, height: 3.2), cornerRadius: 1.6), with: .color(ink))
        }
        // Battery (viewBox 16×8 in 13×6.5 → scale 0.8125).
        do {
            var c = ctx
            c.opacity = 0.62
            c.translateBy(x: 262, y: 2.75)
            c.scaleBy(x: 0.8125, y: 0.8125)
            c.stroke(Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: 13, height: 7), cornerRadius: 2), with: .color(ink), lineWidth: 1)
            c.fill(Path(roundedRect: CGRect(x: 2, y: 2, width: 8, height: 4), cornerRadius: 1), with: .color(ink))
            c.fill(Path(roundedRect: CGRect(x: 14.4, y: 2.6, width: 1.4, height: 2.8), cornerRadius: 0.7), with: .color(ink))
        }
        // Wi-Fi (viewBox 12×9 in 9×7 → scale 0.75).
        do {
            var c = ctx
            c.opacity = 0.62
            c.translateBy(x: 247, y: 2.625)
            c.scaleBy(x: 0.75, y: 0.75)
            c.fill(DemoSVGPath.path(wifiGlyph), with: .color(ink))
        }
        // nanoPod note (viewBox 8×10 in 5×6.5 → scale 0.625), accent-coloured.
        if noteOpacity > 0.001 {
            var c = ctx
            c.opacity = noteOpacity
            let cx: CGFloat = 236 + 2.5, cy: CGFloat = 2.75 + 3.25
            c.translateBy(x: cx, y: cy)
            c.scaleBy(x: CGFloat(noteScale), y: CGFloat(noteScale))
            c.translateBy(x: -cx, y: -cy)
            c.translateBy(x: 236, y: 2.875)
            c.scaleBy(x: 0.625, y: 0.625)
            c.fill(Path(ellipseIn: CGRect(x: 2.5 - 2.2, y: 7.6 - 1.7, width: 4.4, height: 3.4)), with: .color(p.accent))
            c.fill(DemoSVGPath.path("M4 7.4V1l3.4 1.3v1.5L5.2 3v4.4z"), with: .color(p.accent))
        }
    }

    private static let appleGlyph = "M6 3.7c.8-.5 2.2-.6 3.1.6-1.2.8-1.3 2.6.1 3.4-.5 1.5-1.4 3-2.4 3-.5 0-.6-.3-1-.3s-.6.3-1.1.3C3.5 10.7 2.2 7.1 3.3 5.1c.8-1.2 2-1.9 2.7-1.4zM6.4 3.1c0-1 .6-1.9 1.7-2.3 0 1-.5 2-1.7 2.3z"
    private static let wifiGlyph = "M6 8.4l1.5-1.6a2.1 2.1 0 00-3 0zM2.9 5.2l.9.9a3.4 3.4 0 014.4 0l.9-.9a4.7 4.7 0 00-6.2 0zM.8 3l.9.9a6.4 6.4 0 018.6 0L11.2 3a7.7 7.7 0 00-10.4 0z"

    // MARK: panel

    private struct Glow {
        let cx, cy, rx, ry: Double
        let color: Color
        let fadeAt: Double
    }

    private static let albumPink = Color(.sRGB, red: 1, green: 0x9A / 255, blue: 0xA8 / 255, opacity: 1)
    private static let albumViolet = Color(.sRGB, red: 0x7D / 255, green: 0x6C / 255, blue: 1, opacity: 1)
    private static let albumBase = Color(.sRGB, red: 0xB9 / 255, green: 0x50 / 255, blue: 0x8F / 255, opacity: 1)

    /// Panel shell: outside-only drop shadow, gradient body, hairline ring; `content` paints
    /// in panel-local points (origin = panel top-left) already clipped to the rounded body.
    private static func drawPanelChrome(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                                        radius: CGFloat, glows: [Glow], background: ((CGRect) -> GraphicsContext.Shading)? = nil,
                                        content: (inout GraphicsContext) -> Void) {
        let box = CGRect(x: x, y: y, width: width, height: height)
        // box-shadow: 0 .09em .22em rgba(30,20,70,.3) — outside the box only.
        do {
            var c = ctx
            var outside = Path(box.insetBy(dx: -width, dy: -width))
            outside.addPath(Path(roundedRect: box, cornerRadius: radius))
            c.clip(to: outside, style: FillStyle(eoFill: true))
            c.addFilter(.blur(radius: 0.11 * width))
            c.fill(Path(roundedRect: box.offsetBy(dx: 0, dy: 0.09 * width), cornerRadius: radius),
                   with: .color(StageChrome.shadow(0.3)))
        }
        var c = ctx
        c.translateBy(x: x, y: y)
        let local = CGRect(origin: .zero, size: box.size)
        let shape = Path(roundedRect: local, cornerRadius: radius)
        c.clip(to: shape)
        c.fill(Path(local), with: background?(local) ?? .color(albumBase))
        for g in glows { fillEllipticalGlow(&c, in: local, cx: g.cx, cy: g.cy, rx: g.rx, ry: g.ry, color: g.color, fadeAt: g.fadeAt) }
        // inset 0 0 0 .004em rgba(255,255,255,.28)
        let t = 0.004 * width
        var ring = shape
        ring.addPath(Path(roundedRect: local.insetBy(dx: t, dy: t), cornerRadius: max(0, radius - t)))
        c.fill(ring, with: .color(.white.opacity(0.28)), style: FillStyle(eoFill: true))
        content(&c)
    }

    /// Backdrop of the pages that show no cover (lyrics, history) in the fullscreen look: the cover's own
    /// colours (coral sky → violet → deep sea) without the sun, so white text stays readable.
    private static func fullscreenPageBackground(_ rect: CGRect) -> GraphicsContext.Shading {
        cssLinear(170, in: rect, stops: [
            (Color(.sRGB, red: 1, green: 0x7F / 255, blue: 0x8F / 255, opacity: 1), 0),
            (Color(.sRGB, red: 0x6B / 255, green: 0x5B / 255, blue: 0xD6 / 255, opacity: 1), 0.62),
            (Color(.sRGB, red: 0x2F / 255, green: 0x2A / 255, blue: 0x85 / 255, opacity: 1), 1),
        ])
    }

    private static func albumGlows() -> [Glow] {
        [Glow(cx: 0.92, cy: 0.96, rx: 1.0, ry: 0.8, color: albumViolet, fadeAt: 0.58),
         Glow(cx: 0.14, cy: 0.06, rx: 1.1, ry: 0.8, color: albumPink, fadeAt: 0.62)]
    }

    /// The 250:284 album panel (`.pn`), with the cover / title / controls at cover-fill state `cover.s`.
    private static func drawAlbumPanel(_ ctx: inout GraphicsContext, _ p: DemoPalette, x: CGFloat, y: CGFloat, pw: CGFloat, cover f: CoverFrame) {
        drawPanelChrome(&ctx, x: x, y: y, width: pw, height: 1.136 * pw, radius: 0.07 * pw, glows: albumGlows()) { c in
            let s = f.s
            // 1. Blurred colour underlay: the cover's own picture, 1.4em square, blurred 0.17em.
            if s > 0.001 {
                var b = c
                b.opacity = s
                b.addFilter(.blur(radius: 0.17 * pw))
                b.addFilter(.saturation(1.1))
                b.drawLayer { l in
                    let box = CGRect(x: -0.2 * pw, y: -0.12 * pw, width: 1.4 * pw, height: 1.4 * pw)
                    l.clip(to: Path(box))
                    drawCoverPicture(&l, rect: box, sunAlpha: 1)
                }
            }
            // 2. The sharp cover; its bottom band fades into the underlay (mask), no shadow (the mask clips it).
            let side = f.artSide * pw
            let art = CGRect(x: f.artLeft * pw, y: f.artTop * pw, width: side, height: side)
            c.drawLayer { l in
                l.clipToLayer { m in
                    let stops: [Gradient.Stop] = [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 1 - f.fadeBand),
                        .init(color: .black.opacity(f.artOpacityAtBottom), location: 1),
                    ]
                    m.fill(Path(art), with: .linearGradient(Gradient(stops: stops),
                                                             startPoint: CGPoint(x: 0, y: art.minY), endPoint: CGPoint(x: 0, y: art.maxY)))
                }
                // The picture is composed as ONE group first, then masked: masking each stroke
                // separately would let the sun show through the half-faded sea.
                l.drawLayer { g in
                    g.clip(to: Path(roundedRect: art, cornerRadius: f.artRadius * pw))
                    drawCoverPicture(&g, rect: art, sunAlpha: 0.95)
                }
            }
            // 3. Title / artist bars and transport glyphs.
            let titleBar = CGRect(x: 0.16 * pw, y: f.titleTop * pw, width: 0.42 * pw, height: 0.027 * pw)
            c.fill(Path(roundedRect: titleBar, cornerRadius: min(0.02 * pw, titleBar.height / 2)), with: .color(.white.opacity(0.94)))
            let artistBar = CGRect(x: 0.16 * pw, y: f.artistTop * pw, width: 0.27 * pw, height: 0.02 * pw)
            c.fill(Path(roundedRect: artistBar, cornerRadius: min(0.02 * pw, artistBar.height / 2)), with: .color(.white.opacity(0.55)))
            drawTransport(&c, pw: pw, top: f.controlsTop * pw)
        }
    }

    /// `.ctl`: previous · play · next, white, 0.052em tall, 0.15em apart, centred.
    private static func drawTransport(_ ctx: inout GraphicsContext, pw: CGFloat, top: CGFloat) {
        let h = 0.052 * pw
        let widths: [CGFloat] = [0.062 * pw, 0.044 * pw, 0.062 * pw]
        let gap = 0.15 * pw
        let total = widths.reduce(0, +) + 2 * gap
        var x = (pw - total) / 2
        let glyphs: [(String, CGFloat, CGFloat)] = [
            ("M13 1V11L7 6Z M7 1V11L1 6Z", 14, 12), ("M1 1L9 6L1 11Z", 10, 12), ("M1 1V11L7 6Z M7 1V11L13 6Z", 14, 12),
        ]
        for (i, g) in glyphs.enumerated() {
            let box = CGRect(x: x, y: top, width: widths[i], height: h)
            drawSVGGlyph(&ctx, g.0, viewBox: CGSize(width: g.1, height: g.2), in: box, color: .white)
            x += widths[i] + gap
        }
    }

    /// Draws an SVG path into `box` with `preserveAspectRatio="xMidYMid meet"`.
    private static func drawSVGGlyph(_ ctx: inout GraphicsContext, _ d: String, viewBox: CGSize, in box: CGRect, color: Color) {
        let scale = min(box.width / viewBox.width, box.height / viewBox.height)
        var c = ctx
        c.translateBy(x: box.minX + (box.width - viewBox.width * scale) / 2, y: box.minY + (box.height - viewBox.height * scale) / 2)
        c.scaleBy(x: scale, y: scale)
        c.fill(DemoSVGPath.path(d), with: .color(color))
    }

    /// The prototype's sunset cover: 170° sky, sun, sea. `sunAlpha` .95 on the sharp cover, 1 in the underlay.
    private static func drawCoverPicture(_ ctx: inout GraphicsContext, rect: CGRect, sunAlpha: Double) {
        ctx.fill(Path(rect), with: cssLinear(170, in: rect, stops: [
            (Color(.sRGB, red: 1, green: 0xD5 / 255, blue: 0x8F / 255, opacity: 1), 0),
            (Color(.sRGB, red: 1, green: 0x7F / 255, blue: 0x8F / 255, opacity: 1), 0.46),
            (Color(.sRGB, red: 0x6B / 255, green: 0x5B / 255, blue: 0xD6 / 255, opacity: 1), 1),
        ]))
        let sun = CGRect(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.30,
                         width: rect.width * 0.46, height: rect.height * 0.46)
        ctx.fill(Path(ellipseIn: sun), with: .color(Color(.sRGB, red: 1, green: 0xF1 / 255, blue: 0xD0 / 255, opacity: sunAlpha)))
        let sea = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.60, width: rect.width, height: rect.height * 0.42)
        ctx.fill(Path(sea), with: .linearGradient(Gradient(colors: [
            Color(.sRGB, red: 0x5A / 255, green: 0x4B / 255, blue: 0xC4 / 255, opacity: 1),
            Color(.sRGB, red: 0x2F / 255, green: 0x2A / 255, blue: 0x85 / 255, opacity: 1),
        ]), startPoint: CGPoint(x: 0, y: sea.minY), endPoint: CGPoint(x: 0, y: sea.maxY)))
    }

    private static func drawHistoryPanel(_ ctx: inout GraphicsContext, _ p: DemoPalette, x: CGFloat, y: CGFloat, pw: CGFloat) {
        drawPanelChrome(&ctx, x: x, y: y, width: pw, height: 1.136 * pw, radius: 0.07 * pw, glows: [],
                        background: fullscreenPageBackground) { c in
            for i in 0..<4 {
                let top = 0.09 * pw + CGFloat(i) * 0.2 * pw
                let art = CGRect(x: 0.09 * pw, y: top, width: 0.15 * pw, height: 0.15 * pw)
                c.drawLayer { l in
                    l.clip(to: Path(roundedRect: art, cornerRadius: 0.02 * pw))
                    drawCoverPicture(&l, rect: art, sunAlpha: 0.95)
                }
                c.fill(Path(roundedRect: CGRect(x: 0.29 * pw, y: top + 0.035 * pw, width: (0.42 - CGFloat(i) * 0.05) * pw, height: 0.027 * pw), cornerRadius: 0.0135 * pw),
                       with: .color(.white.opacity(0.94)))
                c.fill(Path(roundedRect: CGRect(x: 0.29 * pw, y: top + 0.085 * pw, width: 0.27 * pw, height: 0.02 * pw), cornerRadius: 0.01 * pw),
                       with: .color(.white.opacity(0.55)))
            }
        }
    }

    // MARK: edge strip + song card

    /// `.strip`: 5×40 sliver on the right screen edge with the pink progress light; `pulse` lights it on track change.
    private static func drawEdgeStrip(_ ctx: inout GraphicsContext, _ p: DemoPalette, opacity: Double, offsetX: Double, fillPercent: Double, pulse: Double) {
        guard opacity > 0.001 else { return }
        var c = ctx
        c.fadeGroup(opacity)
        c.translateBy(x: CGFloat(offsetX), y: 0)
        let box = CGRect(x: sceneWidth - 5, y: 70, width: 5, height: 40)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3).path(in: box)
        c.drawLayer { l in
            // Outside-only rings: the 0.5pt hairline and the pulse glow.
            var outside = Path(box.insetBy(dx: -30, dy: -30))
            outside.addPath(shape)
            l.drawLayer { o in
                o.clip(to: outside, style: FillStyle(eoFill: true))
                o.fill(UnevenRoundedRectangle(topLeadingRadius: 3.5, bottomLeadingRadius: 3.5).path(in: box.insetBy(dx: -0.5, dy: -0.5)), with: .color(p.glassLine))
                if pulse > 0.001 {
                    var g = o
                    g.addFilter(.blur(radius: pulse * 6))
                    g.fill(Path(roundedRect: box.insetBy(dx: -pulse * 3, dy: -pulse * 3), cornerRadius: 3 + pulse * 3),
                           with: .color(p.accent.opacity(0.55 * pulse)))
                }
            }
            l.fill(shape, with: .color(p.strip))
            l.drawLayer { f in
                f.clip(to: shape)
                let h = box.height * CGFloat(fillPercent) / 100
                f.fill(Path(roundedRect: CGRect(x: box.minX, y: box.maxY - h, width: box.width, height: h), cornerRadius: 3), with: .color(p.accent))
            }
        }
    }

    /// The vertical song card that peeks out on a track change (0.5× of LiquidEdge's 120×204 card).
    private static func drawSongCard(_ ctx: inout GraphicsContext, _ p: DemoPalette) {
        let box = CGRect(x: sceneWidth - 7 - 60, y: 39, width: 60, height: 102)
        let shape = Path(roundedRect: box, cornerRadius: 13)
        // 0 8px 20px rgba(20,10,40,.35), outside only
        do {
            var c = ctx
            var outside = Path(box.insetBy(dx: -40, dy: -40))
            outside.addPath(shape)
            c.clip(to: outside, style: FillStyle(eoFill: true))
            c.addFilter(.blur(radius: 10))
            c.fill(Path(roundedRect: box.offsetBy(dx: 0, dy: 8), cornerRadius: 13), with: .color(Color(.sRGB, red: 20 / 255, green: 10 / 255, blue: 40 / 255, opacity: 0.35)))
        }
        var c = ctx
        c.clip(to: shape)
        c.fill(shape, with: .linearGradient(Gradient(stops: [
            .init(color: Color(.sRGB, red: 0x9A / 255, green: 0x63 / 255, blue: 0xAB / 255, opacity: 1), location: 0),
            .init(color: Color(.sRGB, red: 0x6D / 255, green: 0x45 / 255, blue: 0x87 / 255, opacity: 1), location: 0.52),
            .init(color: Color(.sRGB, red: 0x1E / 255, green: 0x12 / 255, blue: 0x28 / 255, opacity: 1), location: 1),
        ]), startPoint: CGPoint(x: box.minX, y: 0), endPoint: CGPoint(x: box.maxX, y: 0)))
        c.stroke(shape, with: .color(.white.opacity(0.14)), lineWidth: 1)   // the clip keeps the inner half
        c.translateBy(x: box.minX, y: box.minY)
        // Cover thumbnail 48×48 at (6,6), radius 7; sun 44% at (28%,24%), sea from 58%.
        let th = CGRect(x: 6, y: 6, width: 48, height: 48)
        c.drawLayer { l in
            l.clip(to: Path(roundedRect: th, cornerRadius: 7))
            l.fill(Path(th), with: cssLinear(170, in: th, stops: [
                (Color(.sRGB, red: 1, green: 0xD5 / 255, blue: 0x8F / 255, opacity: 1), 0),
                (Color(.sRGB, red: 1, green: 0x7F / 255, blue: 0x8F / 255, opacity: 1), 0.46),
                (Color(.sRGB, red: 0x6B / 255, green: 0x5B / 255, blue: 0xD6 / 255, opacity: 1), 1),
            ]))
            l.fill(Path(ellipseIn: CGRect(x: th.minX + th.width * 0.28, y: th.minY + th.height * 0.24, width: th.width * 0.44, height: th.height * 0.44)),
                   with: .color(Color(.sRGB, red: 1, green: 0xF1 / 255, blue: 0xD0 / 255, opacity: 0.95)))
            let sea = CGRect(x: th.minX, y: th.minY + th.height * 0.58, width: th.width, height: th.height * 0.5)
            l.fill(Path(sea), with: .linearGradient(Gradient(colors: [
                Color(.sRGB, red: 0x5A / 255, green: 0x4B / 255, blue: 0xC4 / 255, opacity: 1),
                Color(.sRGB, red: 0x2F / 255, green: 0x2A / 255, blue: 0x85 / 255, opacity: 1),
            ]), startPoint: CGPoint(x: 0, y: sea.minY), endPoint: CGPoint(x: 0, y: sea.maxY)))
        }
        c.fill(Path(roundedRect: CGRect(x: 16, y: 60, width: 28, height: 4), cornerRadius: 2), with: .color(.white))
        c.fill(Path(roundedRect: CGRect(x: 21, y: 68, width: 18, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.55)))
        // Play button: 20×20 at (9,77): progress ring (dash 36/90 of the circumference) + triangle.
        do {
            var b = c
            b.translateBy(x: 9, y: 77)
            let ring = Path(ellipseIn: CGRect(x: 10 - 8.6, y: 10 - 8.6, width: 17.2, height: 17.2))
            b.stroke(ring, with: .color(.white.opacity(0.28)), lineWidth: 1.8)
            var arc = Path()
            let circumference = 2 * CGFloat.pi * 8.6
            arc.addArc(center: CGPoint(x: 10, y: 10), radius: 8.6, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * 36 / Double(circumference)), clockwise: false)
            b.stroke(arc, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            b.fill(DemoSVGPath.path("M8 6.3v7.4l6-3.7z"), with: .color(.white))
        }
        drawSVGGlyph(&c, "M1 1V11L7 6Z M7 1V11L13 6Z", viewBox: CGSize(width: 14, height: 12), in: CGRect(x: 38, y: 82, width: 12, height: 10), color: .white)
    }

    // MARK: keys, background window, misc

    /// Three 34pt keycaps (the recorded combination); a dashed empty cap when nothing is recorded.
    private static func drawKeycaps(_ ctx: inout GraphicsContext, _ p: DemoPalette, labels: [String], press d: Double) {
        let top: CGFloat = 76
        var x: CGFloat = 24
        if labels.isEmpty {
            let r = CGRect(x: x, y: top, width: 34, height: 34)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 9), with: .color(p.capInk.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            return
        }
        for label in labels {
            let w: CGFloat = label.count > 1 ? 14 + 9 * CGFloat(label.count) : 34
            drawKeycap(&ctx, p, label: label, rect: CGRect(x: x, y: top, width: w, height: 34), press: d)
            x += w + 6
        }
    }

    private static func drawKeycap(_ ctx: inout GraphicsContext, _ p: DemoPalette, label: String, rect: CGRect, press d: Double) {
        var c = ctx
        // transform: translateY(3d) scale(1 - .05d) about the key centre
        let center = CGPoint(x: rect.midX, y: rect.midY)
        c.translateBy(x: 0, y: CGFloat(d) * 3)
        c.translateBy(x: center.x, y: center.y)
        c.scaleBy(x: CGFloat(1 - d * 0.05), y: CGFloat(1 - d * 0.05))
        c.translateBy(x: -center.x, y: -center.y)
        let r: CGFloat = 9
        // bottom → top of the CSS shadow stack: accent ring, soft shadow, hard lip, face, inset highlight
        if d > 0.05 {
            c.fill(Path(roundedRect: rect.insetBy(dx: -CGFloat(2 * d), dy: -CGFloat(2 * d)), cornerRadius: r + CGFloat(2 * d)),
                   with: .color(p.accent.opacity(0.8 * d)))
        }
        do {
            var s = c
            s.addFilter(.blur(radius: 4))
            s.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: CGFloat(5 - d * 3)), cornerRadius: r),
                   with: .color(StageChrome.shadow(0.16 - d * 0.08)))
        }
        c.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: CGFloat(3 - d * 2.5)), cornerRadius: r), with: .color(p.keyEdge))
        let face = Path(roundedRect: rect, cornerRadius: r)
        c.fill(face, with: .color(p.keyFace))
        let lit = face.subtracting(Path(roundedRect: rect.offsetBy(dx: 0, dy: 1), cornerRadius: r))
        c.fill(lit, with: .color(.white.opacity(0.4)))
        let text = c.resolve(Text(label).font(.system(size: 15, weight: .medium)).foregroundColor(p.keyInk))
        c.draw(text, at: center, anchor: .center)
    }

    private static func drawBackgroundWindow(_ ctx: inout GraphicsContext, _ p: DemoPalette, rect: CGRect) {
        let shape = Path(roundedRect: rect, cornerRadius: 9)
        do {
            var ring = ctx
            var outside = Path(rect.insetBy(dx: -4, dy: -4))
            outside.addPath(shape)
            ring.clip(to: outside, style: FillStyle(eoFill: true))
            ring.stroke(shape, with: .color(p.bgwinLine), lineWidth: 1)   // 0.5pt outside the box
        }
        ctx.fill(shape, with: .color(p.bgwin))
        var c = ctx
        c.clip(to: shape)
        c.translateBy(x: rect.minX, y: rect.minY)
        var dots = c
        dots.opacity = 0.8
        for (i, hex) in [(0, 0xFF5F57), (1, 0xFEBC2E), (2, 0x28C840)] as [(Int, UInt32)] {
            let cx = 8 + 2.5 + CGFloat(i) * 7.5
            dots.fill(Path(ellipseIn: CGRect(x: cx - 2.5, y: 8 + 2.5 - 2.5, width: 5, height: 5)),
                      with: .color(Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)))
        }
        for (top, w) in [(26, 70), (42, 100), (58, 54), (74, 84)] as [(CGFloat, CGFloat)] {
            var b = c
            b.opacity = 0.22
            b.fill(Path(roundedRect: CGRect(x: 10, y: top, width: w, height: 5), cornerRadius: 2.5), with: .color(p.capInk))
        }
    }

    private static func drawGlassCard(_ ctx: inout GraphicsContext, _ p: DemoPalette, rect: CGRect, radius: CGFloat) {
        let shape = Path(roundedRect: rect, cornerRadius: radius)
        var s = ctx
        s.addFilter(.blur(radius: 7))
        s.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 6), cornerRadius: radius), with: .color(StageChrome.shadow(p.dark ? 0.5 : 0.22)))
        ctx.fill(shape, with: .color(p.dark ? Color(.sRGB, red: 44 / 255, green: 44 / 255, blue: 50 / 255, opacity: 0.86) : .white.opacity(0.86)))
        ctx.stroke(shape, with: .color(p.glassLine), lineWidth: 0.5)
    }

    /// The nanoPod app icon stand-in: an accent-gradient rounded square with the note.
    private static func drawAppIcon(_ ctx: inout GraphicsContext, _ p: DemoPalette, rect: CGRect) {
        let shape = Path(roundedRect: rect, cornerRadius: rect.width * 0.26)
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [p.accent.opacity(0.85), p.accent]),
                                              startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        var c = ctx
        let s = rect.width * 0.5 / 10
        c.translateBy(x: rect.midX - 4 * s, y: rect.midY - 5 * s)
        c.scaleBy(x: s, y: s)
        c.fill(Path(ellipseIn: CGRect(x: 2.5 - 2.2, y: 7.6 - 1.7, width: 4.4, height: 3.4)), with: .color(.white))
        c.fill(DemoSVGPath.path("M4 7.4V1l3.4 1.3v1.5L5.2 3v4.4z"), with: .color(.white))
    }

    // MARK: - Gradient helpers (CSS semantics)

    /// CSS `linear-gradient(<angle>deg, …)` over `rect`: the gradient line runs through the
    /// centre at `angle` (0° = up, 90° = right) and is `|w·sin| + |h·cos|` long.
    static func cssLinear(_ angle: Double, in rect: CGRect, stops: [(Color, Double)]) -> GraphicsContext.Shading {
        let a = angle * .pi / 180
        let dir = CGPoint(x: sin(a), y: -cos(a))
        let len = abs(rect.width * sin(a)) + abs(rect.height * cos(a))
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return .linearGradient(
            Gradient(stops: stops.map { Gradient.Stop(color: $0.0, location: $0.1) }),
            startPoint: CGPoint(x: c.x - dir.x * len / 2, y: c.y - dir.y * len / 2),
            endPoint: CGPoint(x: c.x + dir.x * len / 2, y: c.y + dir.y * len / 2))
    }

    /// CSS `radial-gradient(<rx>% <ry>% at <cx>% <cy>%, color 0, transparent <fadeAt>)` inside `rect`
    /// (radii are fractions of the rect's width / height; the ellipse is a scaled unit circle).
    private static func fillEllipticalGlow(_ ctx: inout GraphicsContext, in rect: CGRect, cx: Double, cy: Double,
                                           rx: Double, ry: Double, color: Color, fadeAt: Double) {
        var c = ctx
        c.clip(to: Path(rect))
        c.translateBy(x: rect.minX + rect.width * cx, y: rect.minY + rect.height * cy)
        c.scaleBy(x: rect.width * rx, y: rect.height * ry)
        c.fill(Path(CGRect(x: -1, y: -1, width: 2, height: 2)), with: .radialGradient(
            Gradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0), location: fadeAt)]),
            center: .zero, startRadius: 0, endRadius: 1))
    }
}

// MARK: - Group alpha

extension GraphicsContext {
    /// Fade everything drawn into the next `drawLayer` as ONE group (CSS `opacity` on a parent).
    /// Done with an alpha colour-matrix on the layer rather than `opacity`: in a layer with
    /// translucent fills the plain property was applied on top of the per-op inheritance
    /// (alpha came out squared — 0.28 painted as 0.08), the filter scales the finished group once.
    mutating func fadeGroup(_ alpha: Double) {
        var m = ColorMatrix()
        m.a4 = Float(alpha)
        addFilter(.colorMatrix(m))
    }
}
