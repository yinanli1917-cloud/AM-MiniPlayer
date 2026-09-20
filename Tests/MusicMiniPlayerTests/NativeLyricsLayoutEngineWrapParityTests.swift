import XCTest
import AppKit
import CoreText
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-19 coordinator follow-up: compare, for every real line of 《啟程》(the same song 3k/3l/
// 3n/3o's "未来的旅程" repro is drawn from — full 49-line transcript captured via
// `swift run LyricsVerifier check "啟程" "Christine Fan" 277`, saved at
// `/private/tmp/qicheng_dump.log`; the founder's message said "38 行", this transcript has 49
// non-empty content lines — used all 49 rather than truncating to force a specific count), the
// wrap points / per-visual-line y / per-visual-line height computed by:
//   (a) NSLayoutManager — the engine `NativeLyricsTextSweepLayout.buildLayout` actually uses to
//       position the per-glyph tiles AND (since 3m) the unified dim-base draw.
//   (b) CTFramesetter/CTTypesetter — a same-parameter stand-in for the OLD CATextLayer-driven wrap
//       path the dim base used before 3m unified the two engines (CATextLayer wraps via CoreText
//       internally, not NSLayoutManager).
// at the SAME width (186pt, the founder-reported panel width) and font (24pt semibold, the
// production `mainFontSize`).
//
// Expected result (per the founder's real-device rowdump): only "只有你能带我走向未来的旅程"
// (13 characters, no spaces) disagrees — reported on device as 54pt layer height / row 2 y=24 vs
// every other line's 58pt / y=28.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsLayoutEngineWrapParityTests: XCTestCase {
    private static let panelWidth: CGFloat = 186
    private static let fontSize: CGFloat = 24

    /// The 49 non-empty content lines of 《啟程》, transcribed verbatim from
    /// `/private/tmp/qicheng_dump.log` (real NetEase-sourced lyric text this app actually
    /// fetched and rendered — not a synthetic fixture).
    private static let qichengLines: [String] = [
        "每一天 都有一些事情将会发生",
        "每段路 都有即将要来的旅程",
        "每颗心 都有值得期待的成分",
        "每个人 都有爱上另一个人的可能",
        "想爱就不能害怕会有伤痕",
        "没有人完整",
        "却有人能信任",
        "才找到永恒",
        "想到达明天",
        "现在就要启程",
        "只有你能带我走向未来的旅程",
        "想到达明天",
        "现在就要启程",
        "你能让我看见黑夜过去",
        "天开始明亮的过程",
        "每一天 都有一些事情将会发生",
        "每段路 都有即将要来的旅程",
        "每颗心 都有值得期待的成分",
        "每个人 都有爱上另一个人的可能",
        "想爱就不能害怕会有伤痕",
        "没有人完整",
        "却有人能信任",
        "才找到永恒",
        "想到达明天",
        "现在就要启程",
        "只有你能带我走向未来的旅程",
        "想到达明天",
        "现在就要启程",
        "你能让我看见黑夜过去",
        "想到达明天",
        "现在就要启程",
        "只有你能带我走向未来的旅程",
        "想到达明天",
        "现在就要启程",
        "你能让我看见黑夜过去",
        "天开始明亮的过程",
        "想到达明天",
        "现在就要启程",
        "只有你能带我走向未来的旅程",
        "想到达明天",
        "现在就要启程",
        "你能让我看见",
        "黑夜过去 想到达明天",
        "现在就要启程",
        "只有你能带我走向未来的旅程",
        "想到达明天",
        "现在就要启程",
        "你能让我看见黑夜过去",
        "天开始明亮的过程",
    ]

    struct EngineLineFragment: Equatable {
        let minY: CGFloat
        let height: CGFloat
    }

    /// (a) NSLayoutManager — same construction as `NativeLyricsTextSweepLayout.buildLayout`
    /// (font, paragraph style, container width, zero line-fragment padding).
    private func nsLayoutManagerFragments(for text: String, width: CGFloat, fontSize: CGFloat) -> [EngineLineFragment] {
        let paragraph = NativeLyricsTextSweepLayout.mainParagraphStyle
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .paragraphStyle: paragraph
        ])
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(for: container)
        var fragments: [EngineLineFragment] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            fragments.append(EngineLineFragment(minY: usedRect.minY, height: usedRect.height))
        }
        return fragments
    }

    /// (b) CTFramesetter/CTTypesetter — same font/width, word-wrapping via
    /// `CTTypesetterSuggestLineBreak`, per-line height from CTLine's typographic bounds
    /// (ascent+descent+leading, matching how CATextLayer's CoreText-backed wrap measures a line;
    /// zero explicit line spacing, matching `mainParagraphStyle.lineSpacing == 0`).
    private func coreTextFragments(for text: String, width: CGFloat, fontSize: CGFloat) -> [EngineLineFragment] {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var fragments: [EngineLineFragment] = []
        var start = 0
        let length = attributed.length
        var y: CGFloat = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            let clampedCount = max(1, count)
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, clampedCount))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let height = ascent + descent + leading
            fragments.append(EngineLineFragment(minY: y, height: height))
            y += height
            start += clampedCount
        }
        return fragments
    }

    @MainActor
    func test_49RealQichengLines_wrapAndFragmentHeightsMatchAcrossEngines_exceptKnownException() {
        var mismatches: [(line: String, a: [EngineLineFragment], b: [EngineLineFragment])] = []
        for text in Self.qichengLines {
            let a = nsLayoutManagerFragments(for: text, width: Self.panelWidth, fontSize: Self.fontSize)
            let b = coreTextFragments(for: text, width: Self.panelWidth, fontSize: Self.fontSize)
            let lineCountMatches = a.count == b.count
            let heightsMatch = lineCountMatches && zip(a, b).allSatisfy { abs($0.height - $1.height) < 0.5 }
            let ysMatch = lineCountMatches && zip(a, b).allSatisfy { abs($0.minY - $1.minY) < 0.5 }
            if !lineCountMatches || !heightsMatch || !ysMatch {
                mismatches.append((text, a, b))
            }
        }

        // Table for the report / real-device follow-up.
        var table = ["| line | NSLayoutManager fragments (minY,height) | CTFramesetter fragments (minY,height) | match |",
                      "|---|---|---|---|"]
        for text in Self.qichengLines {
            let a = nsLayoutManagerFragments(for: text, width: Self.panelWidth, fontSize: Self.fontSize)
            let b = coreTextFragments(for: text, width: Self.panelWidth, fontSize: Self.fontSize)
            let match = a.count == b.count
                && zip(a, b).allSatisfy { abs($0.height - $1.height) < 0.5 && abs($0.minY - $1.minY) < 0.5 }
            let aStr = a.map { "(\(String(format: "%.1f", $0.minY)),\(String(format: "%.1f", $0.height)))" }.joined(separator: " ")
            let bStr = b.map { "(\(String(format: "%.1f", $0.minY)),\(String(format: "%.1f", $0.height)))" }.joined(separator: " ")
            table.append("| \(text) | \(aStr) | \(bStr) | \(match ? "✅" : "❌") |")
        }
        print("[NativeLyricsLayoutEngineWrapParityTests] wrap comparison table:\n" + table.joined(separator: "\n"))

        // ACTUAL finding (differs from the founder's stated hypothesis — reported honestly rather
        // than forcing a match): NSLayoutManager and CTFramesetter agree with EACH OTHER on every
        // one of these 49 real lines, including "只有你能带我走向未来的旅程" — there is no
        // engine-vs-engine disagreement at the model level for this text at this width. See the
        // printed table above.
        XCTAssertTrue(
            mismatches.isEmpty,
            "unexpected engine disagreement(s): \(mismatches.map(\.line))"
        )

        // The REAL, reproducible discrepancy this table surfaces (matching the founder's on-device
        // numbers almost exactly: 28pt vs 24pt per fragment, i.e. a 2-line wrap totalling 52-56pt
        // vs 48pt, in the same ballpark as the reported 58pt vs 54pt including padding) is WITHIN
        // each engine, not between them: a 2-line wrap whose FIRST visual line contains a Latin
        // space character (" ", from the lyric's own "每一天 都有…" style phrasing) measures its
        // fragment at ~28pt, while a 2-line wrap with NO space character on that line — like
        // "只有你能带我走向未来的旅程" — measures at ~24pt, for the IDENTICAL nominal font/size.
        // This points to `NSLayoutManager`/CoreText computing a line's height from the tallest
        // font metrics among ITS OWN glyphs, and a Latin space glyph in `NSFont.systemFont` at
        // this size reporting different (taller) ascent+descent+leading than the CJK ideographs
        // it sits beside — a real per-line height variance driven by GLYPH CONTENT (space vs no
        // space), not a bug in this codebase's own math, but exactly the kind of "why does only
        // this one line look different" signal the founder was chasing.
        let firstFragmentHeightByLine: [(text: String, hasSpaceInFirstFragment: Bool, firstHeight: CGFloat)] =
            Self.qichengLines.compactMap { text in
                let a = nsLayoutManagerFragments(for: text, width: Self.panelWidth, fontSize: Self.fontSize)
                guard a.count >= 2, let first = a.first else { return nil }
                // Approximate "does the first visual line contain a space" from the SOURCE text:
                // every 2-line wrap in this corpus that contains a space wraps at-or-after it
                // (word-wrapping never splits mid-word), so a space anywhere in a 2-line text here
                // is on the first line.
                return (text, text.contains(" "), first.height)
            }
        let spacedFirstHeights = Set(firstFragmentHeightByLine.filter(\.hasSpaceInFirstFragment).map { round($0.firstHeight * 10) / 10 })
        let spacelessFirstHeights = Set(firstFragmentHeightByLine.filter { !$0.hasSpaceInFirstFragment }.map { round($0.firstHeight * 10) / 10 })
        print("[NativeLyricsLayoutEngineWrapParityTests] first-fragment heights — with space: \(spacedFirstHeights), without space: \(spacelessFirstHeights)")
        XCTAssertEqual(spacedFirstHeights, [28.0], "expected every space-containing 2-line wrap's first fragment to measure 28pt")
        XCTAssertEqual(spacelessFirstHeights, [24.0], "expected every space-free 2-line wrap's first fragment (e.g. 只有你能带我走向未来的旅程) to measure 24pt — 4pt shorter than a space-containing line, the reproducible root of the founder's reported per-line height difference")
    }
}
