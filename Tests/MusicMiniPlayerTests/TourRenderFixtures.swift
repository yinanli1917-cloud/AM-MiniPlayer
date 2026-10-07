import AppKit
import SwiftUI
import CoreImage
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// Card models for the storyboard scenes, English from the shipping L10n
/// table and Chinese copied from storyboard.html `COPY.zh` (the L10n table is
/// private and follows the machine language).
enum TourSceneFixtures {
    enum Lang { case en, zh }

    private static func t(_ key: String, _ lang: Lang, zh: String) -> String {
        lang == .en ? L10n.localized(key) : zh
    }

    static func welcome(_ lang: Lang, connected: Bool = true) -> TourCardModel {
        var m = TourCardModel(
            kind: .welcome,
            title: t("tour.welcome.title", lang, zh: "你好，很高兴见到你"),
            body: t("tour.welcome.body", lang, zh: "接下来几分钟，我陪你把 nanoPod 走一遍。都是些顺手的小事，不着急。"),
            primaryTitle: t("tour.welcome.primary", lang, zh: "开始"),
            secondaryTitle: t("tour.welcome.secondary", lang, zh: "以后再说"),
            footNote: t("tour.welcome.foot", lang, zh: "随时可以停下，设置里能接着来"),
            ringCompleted: connected ? 1 : 0, stepLabel: connected ? "1" : "0"
        )
        if connected { m.chip = t("tour.welcome.chip", lang, zh: "Music 已经连上了") }
        m.showStop = false; m.showSkipStep = false
        return m
    }

    static func gate(_ lang: Lang) -> TourCardModel {
        var m = TourCardModel(
            kind: .connect,
            title: t("tour.connect.title", lang, zh: "先和 Music 打个招呼"),
            body: t("tour.connect.body", lang, zh: "nanoPod 靠 Music 放歌、读歌词。点一下，系统会问你一次。"),
            primaryTitle: t("tour.connect.primary", lang, zh: "连上 Music"),
            secondaryTitle: t("tour.connect.secondary", lang, zh: "稍后"),
            ringCompleted: 0, stepLabel: "1"
        )
        m.showStop = false; m.showSkipStep = false
        return m
    }

    static func reveal(_ lang: Lang, firstBeatDone: Bool = true) -> TourCardModel {
        TourCardModel(
            kind: .step(.reveal),
            title: t("tour.reveal.title", lang, zh: "把鼠标挪过来"),
            body: t("tour.reveal.body", lang, zh: "面板平时只留封面，控件在你需要的时候才出来。"),
            beats: [TourBeatModel(id: 0, text: t("tour.reveal.beat1", lang, zh: "移到面板上"), checked: firstBeatDone),
                    TourBeatModel(id: 1, text: t("tour.reveal.beat2", lang, zh: "按一下播放"), checked: false)],
            ringCompleted: 1, stepLabel: "2"
        )
    }

    static func lyrics(_ lang: Lang) -> TourCardModel {
        TourCardModel(
            kind: .step(.lyrics),
            title: t("tour.lyrics.title", lang, zh: "歌词在这儿"),
            body: t("tour.lyrics.body", lang, zh: "左下角的小气泡，或者点一下封面。"),
            ringCompleted: 3, stepLabel: "4"
        )
    }

    static func move(_ lang: Lang) -> TourCardModel {
        var m = TourCardModel(
            kind: .step(.moveTuck),
            title: t("tour.move.title", lang, zh: "放到你喜欢的角落"),
            body: t("tour.move.body", lang, zh: "在封面页，双指按住面板往那个角轻推，它会自己落在淡淡的轮廓上。屏幕上的虚影会先带你走一遍。"),
            beats: [TourBeatModel(id: 0, text: t("tour.move.beat1", lang, zh: "推到一个角"), checked: false),
                    TourBeatModel(id: 1, text: t("tour.move.beatDiagonal", lang, zh: "再斜着推到对角"), checked: false),
                    TourBeatModel(id: 2, text: t("tour.move.beat2", lang, zh: "往边上推，让它藏起来"), checked: false)],
            secondaryTitle: t("tour.move.forMe", lang, zh: "替我收起来"),
            footNote: t("tour.move.mouseNote", lang, zh: "用鼠标的话，在 设置 › 快捷键 给「贴边隐藏」录个键就好。"),
            ringCompleted: 4, stepLabel: "6"
        )
        m.showFallbackButton = true
        return m
    }

    static func finale(_ lang: Lang) -> TourCardModel {
        var m = TourCardModel(
            kind: .finale,
            title: t("tour.done.title", lang, zh: "就这些了"),
            body: t("tour.done.body", lang,
                    zh: "往后它就安静地待在一边，想听的时候就在。愿有音乐陪着的时候，都是好时光。"),
            primaryTitle: t("tour.done.shortcut", lang, zh: "录个快捷键"),
            secondaryTitle: t("tour.done.ok", lang, zh: "好"),
            footNote: t("tour.done.foot", lang, zh: "想再走一遍：设置 › 重新认识 nanoPod"),
            ringCompleted: 6, ringClosed: true, stepLabel: ""
        )
        m.showStop = false; m.showSkipStep = false
        return m
    }
}

/// Composes a card render over a desktop-colored backdrop with a frost
/// approximation (blur 18 + saturate 1.5 of the wallpaper under the card,
/// the storyboard's `backdrop-filter`), so the card's CONTENT can be judged
/// on light and dark desktops without a compositor.
enum TourSceneComposer {
    enum Wallpaper {
        case light, dark
        /// Storyboard `--wall-*` stops, lightened for the bright desktop.
        var stops: (a: NSColor, b: NSColor, c: NSColor) {
            switch self {
            case .light: return (NSColor(srgbRed: 0.79, green: 0.84, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.93, green: 0.90, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.72, green: 0.78, blue: 0.90, alpha: 1))
            case .dark: return (NSColor(srgbRed: 0x3A / 255, green: 0x2F / 255, blue: 0x63 / 255, alpha: 1), NSColor(srgbRed: 0x1E / 255, green: 0x1A / 255, blue: 0x38 / 255, alpha: 1), NSColor(srgbRed: 0x6B / 255, green: 0x4E / 255, blue: 0x8F / 255, alpha: 1))
            }
        }
        var name: String { self == .light ? "light" : "dark" }
    }

    static func wallpaper(_ w: Wallpaper, size: CGSize, scale: CGFloat) -> CGImage {
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let stops = w.stops
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [stops.a.cgColor, stops.b.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(ph)), end: CGPoint(x: CGFloat(pw), y: 0), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [stops.c.cgColor, stops.c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: CGFloat(pw) * 0.8, y: 0), startRadius: 0,
                               endCenter: CGPoint(x: CGFloat(pw) * 0.8, y: 0), endRadius: CGFloat(pw) * 0.7, options: [])
        return ctx.makeImage()!
    }

    /// `card` is the ImageRenderer output for `cardSize` points; the card is
    /// placed at `origin` (points, top-left) on a `canvas`-sized wallpaper.
    static func compose(card: CGImage, cardSize: CGSize, shape: TourBubbleShape, wallpaper w: Wallpaper,
                        canvas: CGSize, origin: CGPoint, scale: CGFloat = 2) -> CGImage {
        let wall = wallpaper(w, size: canvas, scale: scale)
        let pw = wall.width, ph = wall.height
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(wall, in: CGRect(x: 0, y: 0, width: pw, height: ph))

        // Frost: blurred + saturated wallpaper, clipped to the bubble.
        let rect = CGRect(x: origin.x * scale, y: (canvas.height - origin.y - cardSize.height) * scale,
                          width: cardSize.width * scale, height: cardSize.height * scale)
        let ci = CIImage(cgImage: wall)
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: ci.clampedToExtent(), kCIInputRadiusKey: 18 * scale]),
           let out = blur.outputImage,
           let sat = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: out, kCIInputSaturationKey: 1.5]),
           let frosted = sat.outputImage,
           let frostCG = CIContext().createCGImage(frosted, from: CGRect(x: 0, y: 0, width: pw, height: ph)) {
            ctx.saveGState()
            var t = CGAffineTransform(translationX: rect.minX, y: rect.maxY).scaledBy(x: scale, y: -scale)
            if let path = shape.path(in: CGRect(origin: .zero, size: cardSize)).cgPath.copy(using: &t) {
                ctx.addPath(path)
                ctx.clip()
                ctx.draw(frostCG, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            }
            ctx.restoreGState()
        }
        // Soft shadow like the storyboard's `--mock-card-shadow` (cheap).
        ctx.draw(card, in: rect)
        return ctx.makeImage()!
    }

    /// Average color of a wallpaper pixel region behind the card (for contrast math).
    static func backdropColor(_ w: Wallpaper) -> NSColor {
        let s = w.stops
        return NSColor(srgbRed: (s.a.redComponent + s.b.redComponent) / 2, green: (s.a.greenComponent + s.b.greenComponent) / 2,
                       blue: (s.a.blueComponent + s.b.blueComponent) / 2, alpha: 1)
    }
}
