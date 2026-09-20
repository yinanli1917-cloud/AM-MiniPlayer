import AppKit
import CoreGraphics
import Foundation

struct NativeLyricsTextSweepMaskLine: Equatable {
    let maskRect: CGRect
    let wavefrontX: CGFloat
}

struct NativeLyricsTranslationSweepMaskLine: Equatable {
    let maskRect: CGRect
    let wavefrontX: CGFloat
}

struct NativeLyricsTranslationSweepVisualLinePlan: Equatable {
    let rect: CGRect
    let width: CGFloat
}

struct NativeLyricsTextSweepVisualRun: Equatable {
    struct Glyph: Equatable {
        let index: Int
        let text: String
        let rect: CGRect
        // 2026-09-20 (3p, founder real-device root cause — 《下雨天》"点点雨似渗出眼泪"): the
        // per-glyph tile's OWN CATextLayer used to render with a hardcoded
        // `NSFont.systemFont(weight:.semibold)` while `rect` (and the whole-line dim base, via
        // `NativeLyricsUnifiedDimDrawLayer`) came from THIS `NSLayoutManager`'s actual glyph
        // layout — for CJK, AppKit resolves that generic UI font to a DIFFERENT concrete font
        // (`.PingFangUIDisplaySC-Semibold`) than what a CATextLayer given the same nominal font
        // resolves to for its own independent Han fallback (`.AppleSystemUIFontDemi`'s own
        // fallback, a different PingFang optical size/variant) — same advance-origin `rect.minX`,
        // different glyph OUTLINE/width at that origin, so bright ink never sits exactly on dim
        // ink underneath: reads as a persistent double-edge/ghost on every swept glyph, worst on
        // the line's last character (rowdump: layoutManagerX == tile.minX exactly, advance
        // 22.8496 exactly, only the FONT differed). `characterIndex` is this glyph's location in
        // the shared `NSTextStorage` (`NativeLyricsUnifiedTextBuild.textStorage`), so a tile
        // renderer can pull the SAME resolved font AppKit already committed to for this exact
        // character via `textStorage.attribute(.font, at: characterIndex, ...)` instead of
        // re-deriving its own generic one. See research/repro-2026-09-20-lyrics-render-3p.md.
        let characterIndex: Int
    }

    let order: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let isEmphasis: Bool
    let rect: CGRect
    let glyphs: [Glyph]
}

struct NativeLyricsTextSweepVisualLinePlan: Equatable {
    let maskRect: CGRect
    let runs: [NativeLyricsTextSweepVisualRun]
}

/// 2026-09-19 (stage bundle 3m, founder-approved "unify the engine, not the dim base" fix):
/// the dim base and the per-glyph tiles used to come from TWO SEPARATELY-BUILT layout objects
/// (`attributedDisplayWrapped`'s own CATextLayer wrap vs this file's `NSLayoutManager`) that were
/// only guaranteed to agree by matching CONFIGURATION (font/width/paragraph style) — 3k/3l proved
/// that agreement holds for every synthetic case tried, but real-device font metrics/real YRC
/// timing/real content width were never verified. `NativeLyricsUnifiedTextBuild` holds the ONE
/// `NSLayoutManager`/`NSTextContainer`/`NSTextStorage` triple so a caller can draw the dim base by
/// calling `layoutManager.drawGlyphs(forGlyphRange:at:)` directly against the SAME object that
/// produced the glyph `rect`s the per-glyph tiles are positioned from — divergence becomes
/// structurally impossible rather than merely improbable. The dim base still paints as ONE
/// whole-line pass (never per-glyph, never floating) — this does not touch the banned per-glyph-
/// float pattern (`.claude/rules/banned-patterns.md`), it only unifies which object computes glyph
/// geometry for the existing whole-line paint.
struct NativeLyricsUnifiedTextBuild {
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let textStorage: NSTextStorage
    let glyphRange: NSRange
    let linePlan: [NativeLyricsTextSweepVisualLinePlan]
}

private struct NativeLyricsTextLineFragment {
    let rect: CGRect
    let glyphRange: NSRange
}

private struct NativeLyricsTokenGlyphPlan {
    let glyph: NativeLyricsTextSweepVisualRun.Glyph
    let glyphRange: NSRange
}

enum NativeLyricsTextSweepLayout {
    static var mainParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        paragraph.lineSpacing = 0
        return paragraph
    }

    static func make(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat,
        fadeHalfPoint: CGFloat,
        currentTime: TimeInterval
    ) -> [NativeLyricsTextSweepMaskLine] {
        maskLines(
            from: makePlan(
                displayText: displayText,
                wordRuns: wordRuns,
                width: width,
                fontSize: fontSize,
                fadeHalfPoint: fadeHalfPoint
            ),
            fadeHalfPoint: fadeHalfPoint,
            currentTime: currentTime
        )
    }

    static func makePlan(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat,
        fadeHalfPoint: CGFloat
    ) -> [NativeLyricsTextSweepVisualLinePlan] {
        buildLayout(
            displayText: displayText, wordRuns: wordRuns, width: width,
            fontSize: fontSize, textColor: nil
        )?.linePlan ?? []
    }

    /// Same layout as `makePlan`, but returns the underlying `NSLayoutManager`/`NSTextContainer`/
    /// `NSTextStorage` triple too, so a caller can paint the dim base by calling
    /// `layoutManager.drawGlyphs(forGlyphRange:at:)` against the EXACT object that produced the
    /// per-glyph tile `rect`s — see `NativeLyricsUnifiedTextBuild`'s doc comment.
    static func makeUnifiedBuild(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat,
        textColor: NSColor
    ) -> NativeLyricsUnifiedTextBuild? {
        buildLayout(
            displayText: displayText, wordRuns: wordRuns, width: width,
            fontSize: fontSize, textColor: textColor
        )
    }

    /// Character range (in `displayText`, NOT glyph space) for each `wordRuns` order — pure text
    /// arithmetic, no layout pass. Used to blank a floating word's range in the shared unified
    /// build's `textStorage` (alpha 0 on that word's `.foregroundColor`) without disturbing the
    /// wrap/geometry the SAME storage already committed to.
    static func characterRanges(for wordRuns: [NativeLyricsWordRunPlan], displayText: String) -> [NSRange] {
        let nsText = displayText as NSString
        var ranges: [NSRange] = []
        var location = 0
        for run in wordRuns {
            let length = (run.text as NSString).length
            defer { location += length }
            guard length > 0, location < nsText.length else {
                ranges.append(NSRange(location: NSNotFound, length: 0))
                continue
            }
            let clamped = min(length, nsText.length - location)
            ranges.append(NSRange(location: location, length: clamped))
        }
        return ranges
    }

    private static func buildLayout(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat,
        textColor: NSColor?
    ) -> NativeLyricsUnifiedTextBuild? {
        guard !displayText.isEmpty, !wordRuns.isEmpty, width > 1 else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .paragraphStyle: NativeLyricsTextSweepLayout.mainParagraphStyle
        ]
        // Color is a paint-time-only attribute (never affects NSLayoutManager's glyph geometry),
        // so setting it here for the "unified draw" caller cannot perturb the wrap points the
        // 08-27 constraint (NativeLyricsActiveLineSpacingTests) depends on. `makePlan`'s geometry-
        // only callers pass nil and inherit the system default color (irrelevant — they never draw).
        if let textColor { attributes[.foregroundColor] = textColor }
        let attributed = NSAttributedString(string: displayText, attributes: attributes)
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var fragments: [NativeLyricsTextLineFragment] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            fragments.append(NativeLyricsTextLineFragment(rect: usedRect, glyphRange: lineGlyphRange))
        }
        guard !fragments.isEmpty else { return nil }

        var visualRunsByLine: [Int: [NativeLyricsTextSweepVisualRun]] = [:]
        let nsText = displayText as NSString
        var characterLocation = 0
        for (order, run) in wordRuns.enumerated() {
            let tokenLength = (run.text as NSString).length
            defer { characterLocation += tokenLength }
            guard tokenLength > 0, characterLocation < nsText.length else { continue }
            let clampedLength = min(tokenLength, nsText.length - characterLocation)
            let characterRange = NSRange(location: characterLocation, length: clampedLength)
            var actualCharacterRange = NSRange(location: NSNotFound, length: 0)
            let tokenGlyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: &actualCharacterRange
            )
            guard tokenGlyphRange.location != NSNotFound, tokenGlyphRange.length > 0 else { continue }
            let tokenRect = layoutManager.boundingRect(forGlyphRange: tokenGlyphRange, in: textContainer)
            guard tokenRect.width > 0, tokenRect.height > 0 else { continue }
            let glyphPlans = glyphPlans(
                for: run.text,
                characterRange: characterRange,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            // 2026-09-20 (3q item 3, founder real-device repro — 《啟程》"只有你能带我走向 /
            // 未来的旅程"): a word RUN's glyph range can span the wrap boundary between two
            // VISUAL lines (common for CJK, where the lyric-source "word" segmentation doesn't
            // align with where NSLayoutManager wraps). The old loop below added a full COPY of
            // this run — same `run.startTime`/`run.endTime` — into every fragment it touched.
            // While line 1 was mid-sweep through that run, line 2's duplicate copy independently
            // evaluated the SAME [startTime, endTime] window against `currentTime` and computed
            // its own nonzero progress fraction, revealing line 2's (narrower) copy of the run in
            // lockstep with line 1 — the founder's "第二行「未来的旅」整段半亮" (a whole
            // not-yet-sung visual line partially lit, tracking line 1's live progress). Fix:
            // collect every intersecting fragment first, then — when a run spans more than one —
            // split its time window PROPORTIONALLY by glyph count across the fragments in reading
            // order, so only the fragment currently under the wavefront has a `startTime` at or
            // before `currentTime`; a not-yet-reached line's slice always starts strictly later.
            struct FragmentMatch {
                let lineIndex: Int
                let glyphRange: NSRange
                let glyphs: [NativeLyricsTextSweepVisualRun.Glyph]
                let rect: CGRect
            }
            var matches: [FragmentMatch] = []
            for (lineIndex, fragment) in fragments.enumerated() {
                let fragmentGlyphRange = NSIntersectionRange(fragment.glyphRange, tokenGlyphRange)
                guard fragmentGlyphRange.length > 0 else { continue }
                let fragmentGlyphs = glyphPlans
                    .filter { NSIntersectionRange($0.glyphRange, fragmentGlyphRange).length > 0 }
                    .map(\.glyph)
                let fragmentRect = glyphBoundingRect(
                    for: fragmentGlyphRange,
                    fallback: tokenRect,
                    glyphs: fragmentGlyphs,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
                guard fragmentRect.width > 0, fragmentRect.height > 0 else { continue }
                matches.append(FragmentMatch(
                    lineIndex: lineIndex,
                    glyphRange: fragmentGlyphRange,
                    glyphs: fragmentGlyphs,
                    rect: fragmentRect
                ))
            }

            if !matches.isEmpty {
                let totalGlyphCount = matches.reduce(0) { $0 + $1.glyphRange.length }
                let runDuration = run.endTime - run.startTime
                var sliceStart = run.startTime
                // `matches` is already in ascending fragment/line order (fragments enumerated in
                // order), which is reading order — so the earliest visual line gets the earliest
                // time slice.
                for match in matches {
                    let isLastMatch = match.lineIndex == matches.last?.lineIndex
                    let sliceDuration: TimeInterval
                    if matches.count == 1 || totalGlyphCount <= 0 {
                        sliceDuration = runDuration
                    } else {
                        let share = Double(match.glyphRange.length) / Double(totalGlyphCount)
                        sliceDuration = isLastMatch
                            ? max(0, run.endTime - sliceStart)
                            : runDuration * share
                    }
                    let sliceEnd = isLastMatch ? run.endTime : sliceStart + sliceDuration
                    visualRunsByLine[match.lineIndex, default: []].append(NativeLyricsTextSweepVisualRun(
                        order: order,
                        startTime: sliceStart,
                        endTime: sliceEnd,
                        text: run.text,
                        isEmphasis: run.isEmphasis || run.emphasis != .inactive,
                        rect: match.rect,
                        glyphs: match.glyphs
                    ))
                    sliceStart = sliceEnd
                }
                continue
            }

            let lineIndex = nearestFragmentIndex(to: tokenRect, in: fragments)
            visualRunsByLine[lineIndex, default: []].append(NativeLyricsTextSweepVisualRun(
                order: order,
                startTime: run.startTime,
                endTime: run.endTime,
                text: run.text,
                isEmphasis: run.isEmphasis || run.emphasis != .inactive,
                rect: tokenRect,
                glyphs: glyphPlans.map(\.glyph)
            ))
        }

        let linePlan = visualRunsByLine.keys.sorted().compactMap { lineIndex -> NativeLyricsTextSweepVisualLinePlan? in
            guard var visualRuns = visualRunsByLine[lineIndex], !visualRuns.isEmpty else { return nil }
            visualRuns.sort {
                if $0.order == $1.order {
                    return $0.rect.minX < $1.rect.minX
                }
                return $0.order < $1.order
            }

            // 2026-09-20 (founder: wrapped rows showed the NEXT visual line partially lit up to the
            // first line's wavefront). The per-visual-line mask layers are SIBLINGS inside one mask;
            // wherever two of them overlap, the union reveals. The old `insetBy(dy: -4)` plus the
            // union with run rects let line N's solid region reach into line N+1's glyph band, so
            // the unsung line inherited line N's sweep. Rule (v2.8 lineRects): a line's mask spans
            // that line's fragment band ONLY — never above or below it — and the horizontal reach
            // (fade slack) comes from the run union.
            let fragmentRect = fragments[lineIndex].rect
            var horizontal = fragmentRect
            for visualRun in visualRuns {
                horizontal = horizontal.union(visualRun.rect)
            }
            let maskRect = CGRect(
                x: horizontal.minX - 20,
                y: fragmentRect.minY,
                width: horizontal.width + 40,
                height: fragmentRect.height
            )
            return NativeLyricsTextSweepVisualLinePlan(maskRect: maskRect, runs: visualRuns)
        }
        return NativeLyricsUnifiedTextBuild(
            layoutManager: layoutManager,
            textContainer: textContainer,
            textStorage: storage,
            glyphRange: glyphRange,
            linePlan: linePlan
        )
    }

    static func maskLines(
        from plan: [NativeLyricsTextSweepVisualLinePlan],
        fadeHalfPoint: CGFloat,
        currentTime: TimeInterval
    ) -> [NativeLyricsTextSweepMaskLine] {
        plan.compactMap { line in
            guard !line.runs.isEmpty else { return nil }
            let wavefront = wavefrontX(
                for: line,
                fadeHalfPoint: fadeHalfPoint,
                currentTime: currentTime
            )
            return NativeLyricsTextSweepMaskLine(maskRect: line.maskRect, wavefrontX: wavefront)
        }
    }

    static func wavefrontX(
        for line: NativeLyricsTextSweepVisualLinePlan,
        fadeHalfPoint: CGFloat,
        currentTime: TimeInterval
    ) -> CGFloat {
        guard !line.runs.isEmpty else { return 0 }
        var wavefront = line.runs[0].rect.minX - fadeHalfPoint
        var previousSweepEnd = wavefront
        for visualRun in line.runs {
            let sweepStart = visualRun.rect.minX - fadeHalfPoint
            let sweepEnd = visualRun.rect.maxX + fadeHalfPoint
            let advanceFrom = previousSweepEnd
            if currentTime >= visualRun.endTime {
                wavefront = sweepEnd
            } else if currentTime > visualRun.startTime {
                let duration = visualRun.endTime - visualRun.startTime
                let progress = duration > 0
                    ? CGFloat((currentTime - visualRun.startTime) / duration)
                    : 1
                wavefront = advanceFrom + (sweepEnd - advanceFrom) * min(1, max(0, progress))
                break
            } else {
                wavefront = min(wavefront, sweepStart)
                break
            }
            previousSweepEnd = sweepEnd
        }
        return wavefront
    }

    private static func nearestFragmentIndex(
        to rect: CGRect,
        in fragments: [NativeLyricsTextLineFragment]
    ) -> Int {
        guard !fragments.isEmpty else { return 0 }
        return fragments.indices.min { lhs, rhs in
            abs(fragments[lhs].rect.midY - rect.midY) < abs(fragments[rhs].rect.midY - rect.midY)
        } ?? 0
    }

    private static func glyphBoundingRect(
        for glyphRange: NSRange,
        fallback: CGRect,
        glyphs: [NativeLyricsTextSweepVisualRun.Glyph],
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> CGRect {
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.width > 0, rect.height > 0 {
            return rect
        }
        if let first = glyphs.first {
            rect = first.rect
            for glyph in glyphs.dropFirst() {
                rect = rect.union(glyph.rect)
            }
            return rect
        }
        return fallback
    }

    private static func glyphPlans(
        for token: String,
        characterRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [NativeLyricsTokenGlyphPlan] {
        let nsToken = token as NSString
        guard nsToken.length > 0 else { return [] }
        var glyphs: [NativeLyricsTokenGlyphPlan] = []
        glyphs.reserveCapacity(nsToken.length)

        for tokenOffset in 0..<nsToken.length {
            let tokenCharacter = nsToken.substring(with: NSRange(location: tokenOffset, length: 1))
            guard !tokenCharacter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let location = characterRange.location + tokenOffset
            guard location < characterRange.location + characterRange.length else { continue }
            let charRange = NSRange(location: location, length: 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: charRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { continue }
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard rect.width > 0, rect.height > 0 else { continue }
            glyphs.append(NativeLyricsTokenGlyphPlan(
                glyph: NativeLyricsTextSweepVisualRun.Glyph(
                    index: glyphs.count,
                    text: tokenCharacter,
                    rect: rect,
                    characterIndex: location
                ),
                glyphRange: glyphRange
            ))
        }
        return glyphs
    }

    struct LayoutSnapshot: Equatable {
        let lineCount: Int
        let fragmentHeights: [CGFloat]
        let fragmentMinYs: [CGFloat]
        let glyphMinXs: [CGFloat]
        let glyphMidYs: [CGFloat]

        var lineSpacing: CGFloat {
            guard fragmentMinYs.count >= 2 else { return 0 }
            return fragmentMinYs[1] - fragmentMinYs[0]
        }

        var meanGlyphAdvance: CGFloat {
            guard glyphMinXs.count >= 2 else { return 0 }
            let gaps = zip(glyphMinXs.dropFirst(), glyphMinXs).map { $0 - $1 }
            return gaps.reduce(0, +) / CGFloat(gaps.count)
        }
    }

    /// Layout-only snapshot of wrap fragments and glyph origins. Independent of
    /// isActive / float — this is the typesetting the dim base must keep across
    /// activation (founder 2026-08-27 行距 bug).
    static func layoutSnapshot(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat
    ) -> LayoutSnapshot {
        layoutSnapshot(from: makePlan(
            displayText: displayText,
            wordRuns: wordRuns,
            width: width,
            fontSize: fontSize,
            fadeHalfPoint: 12
        ))
    }

    /// Same reduction as the `displayText`-taking overload, but from an ALREADY-BUILT plan — so a
    /// caller holding the row's actual active-frame `linePlan` (built from the shared
    /// `NativeLyricsUnifiedTextBuild` the dim base itself draws from) can snapshot exactly what
    /// was rendered, instead of rebuilding a second, separately-constructed plan to compare
    /// against. Stage bundle 3m: `NativeLyricsActiveLineSpacingTests` uses this to compare the
    /// row's live active-frame geometry against a pre-activation baseline built from this SAME
    /// reduction, in place of the old `mainTextLayer.string != nil` mechanism check.
    static func layoutSnapshot(from plan: [NativeLyricsTextSweepVisualLinePlan]) -> LayoutSnapshot {
        var heights: [CGFloat] = []
        var minYs: [CGFloat] = []
        var glyphMinXs: [CGFloat] = []
        var glyphMidYs: [CGFloat] = []
        for line in plan {
            guard !line.runs.isEmpty else { continue }
            let minY = line.runs.map(\.rect.minY).min() ?? 0
            let maxY = line.runs.map(\.rect.maxY).max() ?? minY
            heights.append(maxY - minY)
            minYs.append(minY)
            for run in line.runs {
                for glyph in run.glyphs {
                    glyphMinXs.append(glyph.rect.minX)
                    glyphMidYs.append(glyph.rect.midY)
                }
            }
        }
        return LayoutSnapshot(
            lineCount: heights.count,
            fragmentHeights: heights,
            fragmentMinYs: minYs,
            glyphMinXs: glyphMinXs,
            glyphMidYs: glyphMidYs
        )
    }
}

enum NativeLyricsTranslationSweepLayout {
    static func makePlan(
        text: String,
        width: CGFloat,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> [NativeLyricsTranslationSweepVisualLinePlan] {
        guard !text.isEmpty, width > 1 else { return [] }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .paragraphStyle: paragraph
            ]
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lines: [NativeLyricsTranslationSweepVisualLinePlan] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            guard usedRect.width > 0, usedRect.height > 0 else { return }
            lines.append(NativeLyricsTranslationSweepVisualLinePlan(
                rect: usedRect,
                width: usedRect.width
            ))
        }
        return lines
    }

    static func maskLines(
        from plan: [NativeLyricsTranslationSweepVisualLinePlan],
        progress: CGFloat,
        fadeHalfPoint: CGFloat
    ) -> [NativeLyricsTranslationSweepMaskLine] {
        guard !plan.isEmpty else { return [] }
        let totalWidth = plan.reduce(CGFloat.zero) { $0 + $1.width }
        guard totalWidth > 0 else { return [] }
        let filledWidth = min(1, max(0, progress)) * totalWidth
        var accumulated: CGFloat = 0
        var lines: [NativeLyricsTranslationSweepMaskLine] = []
        for line in plan {
            let localFilled = filledWidth - accumulated
            defer { accumulated += line.width }
            let maskRect = line.rect.insetBy(dx: -20, dy: 0)
            let wavefront: CGFloat
            if localFilled <= 0 {
                wavefront = maskRect.minX - fadeHalfPoint
            } else {
                let localProgress = min(1, max(0, localFilled / max(1, line.width)))
                wavefront = line.rect.minX + line.rect.width * localProgress
            }
            lines.append(NativeLyricsTranslationSweepMaskLine(
                maskRect: maskRect,
                wavefrontX: wavefront
            ))
        }
        return lines
    }

    static func maskLinesSequential(
        from plan: [NativeLyricsTranslationSweepVisualLinePlan],
        currentTime: TimeInterval,
        lineStartTime: TimeInterval,
        lineEndTime: TimeInterval,
        fadeHalfPoint: CGFloat
    ) -> [NativeLyricsTranslationSweepMaskLine] {
        guard !plan.isEmpty else { return [] }
        let n = plan.count
        let totalDuration = lineEndTime - lineStartTime
        guard totalDuration > 0 else {
            return maskLines(from: plan, progress: 1, fadeHalfPoint: fadeHalfPoint)
        }
        var lines: [NativeLyricsTranslationSweepMaskLine] = []
        for (index, line) in plan.enumerated() {
            let segmentStart = lineStartTime + totalDuration * Double(index) / Double(n)
            let segmentEnd = lineStartTime + totalDuration * Double(index + 1) / Double(n)
            let segmentDuration = segmentEnd - segmentStart
            let localProgress: CGFloat
            if currentTime >= segmentEnd {
                localProgress = 1
            } else if currentTime <= segmentStart || segmentDuration <= 0 {
                localProgress = 0
            } else {
                localProgress = CGFloat((currentTime - segmentStart) / segmentDuration)
            }
            let maskRect = line.rect.insetBy(dx: -20, dy: 0)
            let wavefront: CGFloat
            if localProgress <= 0 {
                wavefront = maskRect.minX - fadeHalfPoint
            } else {
                wavefront = line.rect.minX + line.rect.width * min(1, localProgress)
            }
            lines.append(NativeLyricsTranslationSweepMaskLine(
                maskRect: maskRect,
                wavefrontX: wavefront
            ))
        }
        return lines
    }
}
