import XCTest
import AppKit
import CoreText
@testable import MusicMiniPlayerCore

final class GlyphLayoutAgreementTests: XCTestCase {

    private func ctLineLeftOffsets(for text: String, font: NSFont) -> [CGFloat] {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var offsets: [CGFloat] = []
        let ns = text as NSString
        for i in 0..<ns.length {
            offsets.append(CTLineGetOffsetForStringIndex(line, i, nil))
        }
        return offsets
    }

    private func makeLine(_ chars: [String], wordDur: TimeInterval = 1.0) -> LyricLine {
        var words: [LyricWord] = []
        var t: TimeInterval = 0
        for c in chars {
            words.append(LyricWord(word: c, startTime: t, endTime: t + wordDur))
            t += wordDur
        }
        return LyricLine(text: chars.joined(), startTime: 0, endTime: t, words: words)
    }

    private func run(chars: [String], label: String, width: CGFloat = 2000, lineIndex: Int = 0) {
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let line = makeLine(chars)
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: 0.5, isActive: true
        ))
        let linePlan = NativeLyricsTextSweepLayout.makePlan(
            displayText: plan.displayText, wordRuns: plan.wordRuns, width: width,
            fontSize: plan.constants.mainFontSize, fadeHalfPoint: plan.constants.fadeHalfPoint
        )
        guard linePlan.indices.contains(lineIndex) else {
            XCTFail("\(label): makePlan produced \(linePlan.count) line(s), wanted index \(lineIndex)")
            return
        }
        let fragment = linePlan[lineIndex]
        var nsLayoutLeftEdges: [CGFloat] = []
        for r in fragment.runs.sorted(by: { $0.order < $1.order }) {
            for glyph in r.glyphs { nsLayoutLeftEdges.append(glyph.rect.minX) }
        }
        // Reconstruct JUST this fragment's own text (its runs, in order) — this mirrors what
        // production actually renders in the whole-line CATextLayer: each wrapped fragment is
        // pre-split at the SAME NSLayoutManager wrap points (attributedDisplayWrapped) and joined
        // with explicit `\n`, so CATextLayer lays out EACH fragment independently starting at its
        // own x=0 — a fresh CTLine per fragment is the accurate proxy, not one CTLine for the
        // whole multi-line string.
        let full = fragment.runs.sorted(by: { $0.order < $1.order }).map(\.text).joined()
        let fullChars = Array(full)
        // NativeLyricsTextSweepLayout.glyphPlans SKIPS whitespace (no glyph.rect for a space) —
        // filter CoreText's per-character offsets down to the SAME non-whitespace positions so
        // the two series line up character-for-character.
        let ctAllOffsets = ctLineLeftOffsets(for: full, font: font)
        guard ctAllOffsets.count == fullChars.count else {
            XCTFail("\(label): CT offset count \(ctAllOffsets.count) != fragment char count \(fullChars.count) (\(full))")
            return
        }
        var ctOffsets: [CGFloat] = []
        var labels: [String] = []
        for (i, ch) in fullChars.enumerated() where !ch.isWhitespace {
            ctOffsets.append(ctAllOffsets[i])
            labels.append(String(ch))
        }
        guard let ctFirst = ctOffsets.first, let nsFirst = nsLayoutLeftEdges.first,
              ctOffsets.count == nsLayoutLeftEdges.count else {
            XCTFail("\(label): count mismatch ct=\(ctOffsets.count) ns=\(nsLayoutLeftEdges.count) displayText=\(full)")
            return
        }
        print("[GLYPH-AGREE] \(label): char-by-char relative-offset delta (CoreText vs NSLayoutManager), pt")
        var maxDelta: CGFloat = 0
        for i in 0..<ctOffsets.count {
            let ctRel = ctOffsets[i] - ctFirst
            let nsRel = nsLayoutLeftEdges[i] - nsFirst
            let delta = abs(ctRel - nsRel)
            maxDelta = max(maxDelta, delta)
            print(String(format: "[GLYPH-AGREE]   char[%d]=%@ ctRel=%.3f nsRel=%.3f delta=%.3f",
                          i, labels[i], ctRel, nsRel, delta))
        }
        print(String(format: "[GLYPH-AGREE] \(label) maxDelta=%.3fpt", maxDelta))
    }

    func test_glyphPositionAgreement_cjkLine() {
        run(chars: ["爱", "愁", "思", "心", "碎", "滋", "味"], label: "CJK")
    }

    func test_glyphPositionAgreement_englishLine() {
        // Trailing space attached to the word (project convention — LyricWord tokens carry their
        // own trailing space; a standalone space-only token gets stripped from displayText,
        // which desynced this test's char count against plan.displayText on the first attempt).
        run(chars: ["What ", "it ", "is ", "all ", "about"], label: "English")
    }

    // Real lyric lines routinely wrap. A narrow width forces a SECOND fragment — the wrap point
    // itself is guaranteed to agree (both `wrapLineRanges` and `makePlan` use NSLayoutManager),
    // but each fragment's WITHIN-line glyph positions are what actually gets drawn — test the
    // second (post-wrap) fragment specifically, both scripts.
    func test_glyphPositionAgreement_cjkLine_wrappedSecondFragment() {
        run(chars: ["爱", "愁", "思", "心", "碎", "滋", "味", "苦", "涩", "又", "回", "甘"],
            label: "CJK-wrapped-line2", width: 130, lineIndex: 1)
    }

    func test_glyphPositionAgreement_englishLine_wrappedSecondFragment() {
        run(chars: ["What ", "it ", "is ", "all ", "about ", "tonight ", "and ", "forever"],
            label: "English-wrapped-line2", width: 130, lineIndex: 1)
    }
}
