import AppKit
import XCTest
@testable import MusicMiniPlayerCore

/**
 * [INPUT]: Depends on `ButtonIconLegibility`/`ButtonIconCompositeSampler`/`ButtonIconDecision`/
 *          `APCAContrast` (ButtonIconLegibility.swift) and `BackdropLegibilityBand` (its WCAG
 *          primitives, reused here ONLY inside this file's own frozen "legacy" reimplementation
 *          for before/after comparison — production no longer calls them for this decision).
 * [OUTPUT]: Exports nothing (test target) — a labelled eval matrix (synthetic fixtures +
 *           the founder's real ArtworkCache covers, guarded/skipped when absent) pinning
 *           the 2026-09-25 statistic+APCA fix's white/gray calls, plus a non-asserting
 *           diagnostic that counts how many real covers flip under the OLD vs NEW pipeline.
 * [POS]: Tests/ 的 ButtonIconLegibility 标签化验收集 — founder 2026-09-25 bug report
 *        (Bad Sweetheart "Damn": saturated teal + thin white linework wrongly went gray).
 */

/// Labelled before/after eval for the 2026-09-25 fix to `ButtonIconLegibility` (see that
/// file's header for the full root-cause writeup): the OLD mechanism sampled a button's
/// patch via p90-of-luminance and judged legibility via WCAG 2 contrast; both were wrong
/// for a real founder-reported cover. The NEW mechanism samples a blurred-patch MEDIAN and
/// judges legibility via APCA.
///
/// This file's `legacy*` helpers are a frozen, TEST-ONLY reimplementation of the OLD
/// statistic+metric pair (production deleted them — see `ButtonIconCompositeBitmap.dominantColor`
/// and `ButtonIconDecision`) — kept here solely so the eval can show the wrong old answer
/// next to the corrected new one, without reverting production code. They must never be
/// "fixed" to match new behaviour; that would defeat the point of the comparison.
final class ButtonIconLegibilityEvalTests: XCTestCase {

    private let panelSize = CGSize(width: PanelWindowMetrics.defaultSize.width, height: PanelWindowMetrics.defaultSize.height)

    // MARK: - Fixture builders

    private func makeSolidImage(size: Int = 300, r: CGFloat, g: CGFloat, b: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// A saturated teal field with thin white diagonal linework covering a MINORITY of the
    /// area (~20% — stripes 20pt apart, 4pt wide) — a portable stand-in for the founder's
    /// real "Damn" cover (saturated teal illustration, thin white squiggly linework) that
    /// does not depend on any file being present on disk.
    private func makeTealWithThinWhiteLines(size: Int = 300) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: 0.0, green: 0.55, blue: 0.50, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 4
        var x: CGFloat = -CGFloat(size)
        while x < CGFloat(size) * 2 {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + CGFloat(size), y: CGFloat(size)))
            x += 20
        }
        path.stroke()
        image.unlockFocus()
        return image
    }

    // MARK: - Legacy (pre-2026-09-25) reimplementation — TEST-SIDE ONLY, frozen for comparison

    /// The OLD statistic: p90-of-luminance over the raw (unblurred) patch. Byte-for-byte
    /// the same algorithm `ButtonIconCompositeBitmap.p90Color` used before 2026-09-25.
    private func legacyP90Color(bitmap: ButtonIconCompositeBitmap, rect: ButtonIconRect) -> BackdropLegibilityBand.RGBColor? {
        let scale = bitmap.scale
        let width = bitmap.width
        let height = bitmap.height
        let pixels = bitmap.pixels
        let colLeft = max(0, Int((rect.x * scale).rounded(.down)))
        let colRight = min(width, Int(((rect.x + rect.width) * scale).rounded(.up)))
        let rowTop = max(0, Int((CGFloat(height) - (rect.distanceFromBottom + rect.height) * scale).rounded(.down)))
        let rowBottom = min(height, Int((CGFloat(height) - rect.distanceFromBottom * scale).rounded(.up)))
        guard colRight > colLeft, rowBottom > rowTop else { return nil }

        var samples: [(pixel: BackdropLegibilityBand.RGBColor, luminance: Double)] = []
        samples.reserveCapacity((colRight - colLeft) * (rowBottom - rowTop))
        for row in rowTop..<rowBottom {
            for col in colLeft..<colRight {
                let offset = (row * width + col) * 4
                guard offset + 2 < pixels.count else { continue }
                let r = Double(pixels[offset]) / 255.0
                let g = Double(pixels[offset + 1]) / 255.0
                let b = Double(pixels[offset + 2]) / 255.0
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                samples.append((BackdropLegibilityBand.RGBColor(r: r, g: g, b: b), luminance))
            }
        }
        guard !samples.isEmpty else { return nil }
        let sortedIndices = samples.indices.sorted { samples[$0].luminance < samples[$1].luminance }
        let p90Index = sortedIndices[Int((Double(sortedIndices.count - 1) * 0.9).rounded())]
        return samples[p90Index].pixel
    }

    /// The OLD decision: WCAG contrast, 3.0/3.5 hysteresis, gray solved to the WCAG 3:1 floor.
    private func legacyDecision(color: BackdropLegibilityBand.RGBColor, previous: ButtonIconTone) -> ButtonIconTone {
        let contrast = BackdropLegibilityBand.whiteContrastRatio(relativeLuminance: BackdropLegibilityBand.relativeLuminance(color))
        switch previous {
        case .white:
            guard contrast < 3.0 else { return .white }
        case .gray:
            guard contrast < 3.5 else { return .white }
        }
        let backgroundLuminance = BackdropLegibilityBand.relativeLuminance(color)
        let solvedLinear = (backgroundLuminance + 0.05) / 3.0 - 0.05
        let clamped = min(max(solvedLinear, 0.02), 1)
        return .gray(BackdropLegibilityBand.linearToSRGB(clamped))
    }

    private func legacyResolveAll(cover: NSImage, tone: ArtworkBackgroundToneMap) -> [ButtonIconID: ButtonIconTone] {
        guard let bitmap = ButtonIconCompositeSampler.render(
            cover: cover, tone: tone, totalFadeHeight: ButtonIconLegibility.fullscreenHeroFadeHeight,
            panelSize: panelSize, scale: ButtonIconLegibility.fullscreenCompositeScale
        ) else { return [:] }
        var result: [ButtonIconID: ButtonIconTone] = [:]
        for id in ButtonIconID.allCases {
            let rect = ButtonIconRects.rect(for: id, panelSize: panelSize)
            guard let color = legacyP90Color(bitmap: bitmap, rect: rect) else { continue }
            result[id] = legacyDecision(color: color, previous: .white)
        }
        return result
    }

    private func isWhite(_ tone: ButtonIconTone?) -> Bool {
        tone == .white
    }

    private func isGray(_ tone: ButtonIconTone?) -> Bool {
        guard case .gray = tone else { return false }
        return true
    }

    // MARK: - Synthetic labelled eval (portable — no dependency on local files)

    /// teal + thin white linework -> WHITE. This is the exact class of founder-reported
    /// false positive (Bad Sweetheart "Damn", see `test_realCover_badSweetheart_damn_*`
    /// below for the actual production numbers on the real file) — under the OLD
    /// mechanism, p90 over a small patch containing a diagonal white stroke would read as
    /// near-white; the median of a lightly blurred patch reads as teal instead.
    func test_synthetic_tealWithThinWhiteLines_isWhite() {
        let cover = makeTealWithThinWhiteLines()
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertTrue(isWhite(result[id]), "\(id): teal + thin white linework must stay WHITE, got \(String(describing: result[id]))")
        }
    }

    /// near-white paper -> GRAY (white icons are genuinely unreadable here; this is the
    /// case the mechanism exists for).
    func test_synthetic_nearWhitePaper_isGray() {
        let cover = makeSolidImage(r: 0.97, g: 0.96, b: 0.95)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertTrue(isGray(result[id]), "\(id): near-white paper must flip to GRAY, got \(String(describing: result[id]))")
        }
    }

    /// pale yellow -> GRAY (a cream/pale cover, e.g. the Karen Mok "Winter Solstice" class
    /// of real cover — see the real-file test below).
    func test_synthetic_paleYellow_isGray() {
        let cover = makeSolidImage(r: 0.98, g: 0.95, b: 0.80)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertTrue(isGray(result[id]), "\(id): pale yellow must flip to GRAY, got \(String(describing: result[id]))")
        }
    }

    /// Saturated MID red/blue/green (moderate brightness, not a pure 0/255 primary — pure
    /// saturated green in particular is deceptively BRIGHT under Rec.709 luminance
    /// weighting and legitimately does need gray; that is correct APCA behaviour, not a
    /// case this label covers) -> WHITE, the headline case APCA fixes over WCAG 2 for
    /// saturated hues.
    func test_synthetic_saturatedMidColors_areWhite() {
        let cases: [(name: String, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            ("mid red", 0.75, 0.15, 0.15),
            ("mid green", 0.15, 0.55, 0.20),
            ("mid blue", 0.15, 0.25, 0.75),
        ]
        for c in cases {
            let cover = makeSolidImage(r: c.r, g: c.g, b: c.b)
            let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
            let result = ButtonIconLegibility.resolveAll(
                fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
                reduceTransparency: false, previous: [:]
            )
            for id in ButtonIconID.allCases {
                XCTAssertTrue(isWhite(result[id]), "\(id) on \(c.name): saturated mid-tone colours must stay WHITE, got \(String(describing: result[id]))")
            }
        }
    }

    /// mid gray 0.5 -> decide and document. A flat 0.5 gamma-gray is dark enough (APCA
    /// weighs white-on-mid-gray far above the 45 floor — see `ButtonIconDecision`) that it
    /// stays WHITE; this is not a boundary case, just a documented reference point.
    func test_synthetic_midGray_decisionIsDocumented() {
        let cover = makeSolidImage(r: 0.5, g: 0.5, b: 0.5)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertTrue(isWhite(result[id]), "\(id): mid gray 0.5 documented decision is WHITE (comfortably above the APCA floor)")
        }
    }

    // MARK: - Real covers (founder's machine only — read-only, never copied into the repo;
    // skipped entirely when the file is absent, e.g. CI or another machine)

    private let artworkCacheDir = "/Users/yinanli/Library/Application Support/nanoPod/ArtworkCache"

    /// SHA256(persistentID "E0EA60F7831DAE91") — Bad Sweetheart / "Damn" (album "Bye Bye
    /// That's All"), matched via `playback-history.json` + `MusicController+Artwork.swift`'s
    /// `artworkCacheKey` (persistentID-keyed disk cache filename). Confirmed by inspection:
    /// a saturated teal illustration, thin white squiggly linework, a dark red rotary
    /// telephone near the bottom-right — exactly the founder's 2026-09-25 report.
    private var badSweetheartDamnPath: String { artworkCacheDir + "/ca58b5267510c2d9f12a13733293d0f8355babad0b709b0b82fea003d476bb47.jpg" }

    /// SHA256("meta:winter solstice|karen mok|golden flower") — Karen Mok "Winter
    /// Solstice" (album "Golden Flower"), matched via the same history + the
    /// `artworkMetadataCacheKey` fallback path (`MusicController+Artwork.swift`).
    /// Confirmed by inspection: a pale cream/near-white cover.
    private var karenMokWinterSolsticePath: String { artworkCacheDir + "/9fc428c4aa994b2c8be5fc1e1b56f1c7b9598f68f049b63fc998f7bfe56a7fdf.jpg" }

    private func loadRealCover(_ path: String) throws -> NSImage {
        guard let image = NSImage(contentsOfFile: path) else {
            throw XCTSkip("real cover not present on this machine: \(path)")
        }
        return image
    }

    /// THE regression pin for the founder's exact report. Before the 2026-09-25 fix, this
    /// cover's real production numbers (captured via a one-off probe against the
    /// pre-fix code, on this same file) were:
    ///   shuffle:      p90 color (0.251, 0.757, 0.714), WCAG contrast 2.21 -> GRAY (wrong)
    ///   repeatButton: p90 color (0.325, 0.776, 0.733), WCAG contrast 2.07 -> GRAY (wrong)
    /// This test pins the CORRECTED behaviour and shows the OLD (frozen `legacy*` helpers)
    /// vs NEW decision side by side so a future change cannot silently regress back to gray.
    func test_realCover_badSweetheartDamn_oldWasGray_newIsWhite() throws {
        let cover = try loadRealCover(badSweetheartDamnPath)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())

        let legacy = legacyResolveAll(cover: cover, tone: tone)
        let fixed = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )

        for id in ButtonIconID.allCases {
            print("[eval] Bad Sweetheart Damn \(id): OLD=\(String(describing: legacy[id])) NEW=\(String(describing: fixed[id]))")
            XCTAssertTrue(isGray(legacy[id]), "\(id): sanity check — the OLD p90+WCAG pipeline must reproduce the founder-reported bug on this exact file, got \(String(describing: legacy[id]))")
            XCTAssertTrue(isWhite(fixed[id]), "\(id): the FIXED median+APCA pipeline must resolve WHITE on the founder's real cover, got \(String(describing: fixed[id]))")
        }
    }

    /// Karen Mok "Winter Solstice" — a real pale/cream cover that must still correctly flip
    /// to gray under the new pipeline (the founder's other complaint: near-white covers
    /// must NOT stop flipping just because the teal false-positive got fixed).
    func test_realCover_karenMokWinterSolstice_isGray() throws {
        let cover = try loadRealCover(karenMokWinterSolsticePath)
        let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
        let result = ButtonIconLegibility.resolveAll(
            fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
            reduceTransparency: false, previous: [:]
        )
        for id in ButtonIconID.allCases {
            XCTAssertTrue(isGray(result[id]), "\(id): Karen Mok Winter Solstice (pale/cream) must flip to GRAY, got \(String(describing: result[id]))")
        }
    }

    // MARK: - Diagnostic (non-asserting): how many real covers flip under OLD vs NEW

    /// Scans the founder's entire real `ArtworkCache` (read-only, never written to, never
    /// copied anywhere) and prints how many of the shuffle-button decisions differ between
    /// the OLD (p90+WCAG) and NEW (median+APCA) pipeline. Skipped entirely when the
    /// directory is absent. Not an assertion — real album art is uncontrolled data; this is
    /// a reporting aid, not a pass/fail gate.
    func test_diagnostic_artworkCacheCorpus_oldVsNewFlipCounts() throws {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: artworkCacheDir) else {
            throw XCTSkip("ArtworkCache not present on this machine")
        }
        var total = 0
        var oldGray = 0
        var newGray = 0
        var changedToWhite = 0 // old gray, new white (the bug this fix targets)
        var changedToGray = 0 // old white, new gray (would be a regression direction)

        for file in files.sorted() where file.hasSuffix(".jpg") {
            guard let cover = NSImage(contentsOfFile: artworkCacheDir + "/" + file) else { continue }
            let tone = ArtworkBackgroundToneMap.forMetrics(cover.artworkVisualMetrics())
            let legacy = legacyResolveAll(cover: cover, tone: tone)
            let fixed = ButtonIconLegibility.resolveAll(
                fullscreen: true, artwork: cover, tone: tone, panelSize: panelSize,
                reduceTransparency: false, previous: [:]
            )
            guard let oldTone = legacy[.shuffle], let newTone = fixed[.shuffle] else { continue }
            total += 1
            if isGray(oldTone) { oldGray += 1 }
            if isGray(newTone) { newGray += 1 }
            if isGray(oldTone), isWhite(newTone) { changedToWhite += 1 }
            if isWhite(oldTone), isGray(newTone) { changedToGray += 1 }
        }

        print("[ButtonIconLegibility eval] ArtworkCache corpus: \(total) covers")
        print("[ButtonIconLegibility eval]   OLD (p90+WCAG) gray count: \(oldGray)")
        print("[ButtonIconLegibility eval]   NEW (median+APCA) gray count: \(newGray)")
        print("[ButtonIconLegibility eval]   flipped gray->white (bug fixed): \(changedToWhite)")
        print("[ButtonIconLegibility eval]   flipped white->gray (new gray call): \(changedToGray)")
    }
}
