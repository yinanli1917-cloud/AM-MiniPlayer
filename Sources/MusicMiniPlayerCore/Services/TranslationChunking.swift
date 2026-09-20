/**
 * [INPUT]: Foundation + Translation framework (macOS 15+) + ScriptRunSegmenter
 *          (Utils, pure script-based line segmentation).
 * [OUTPUT]: Chunked, timeout-bounded translation execution (`run`) + its
 *           mixed-script variant (`runMultiScript`, 2026-09-20 — routes each
 *           script run in a line to its own per-language executor batch) +
 *           a per-process memoized TranslationSession.Configuration
 *           availability check.
 * [POS]: Services — used by LyricsService.performSystemTranslation (task A5;
 *        runMultiScript added for the NewJeans "How Sweet" mixed Hangul+Latin
 *        half-translation bug).
 *
 * Why chunking: `performSystemTranslation` used to await ONE batch covering
 * the whole song — a slow or stuck on-device model held the "translating"
 * dots lit for the entire song and a hang never recovered. Splitting into
 * bounded chunks lets each chunk publish (and fail) independently: a stuck
 * chunk times out silently (banned-patterns: never trigger system UI /
 * popups) and the chunks that DID come back still land — this is what makes
 * incremental/progressive translation possible instead of all-or-nothing.
 *
 * `LyricsTranslationExecuting` is the seam that lets tests inject a fake
 * translator (no real Translation framework needed in the test target) —
 * `TranslationSession` conforms via the extension at the bottom of this file.
 */

import Foundation
#if canImport(Translation)
import Translation
#endif

// ============================================================================
// MARK: - Translation executor seam
// ============================================================================

public protocol LyricsTranslationExecuting {
    /// Translates `texts` in order, returning translated text at the same
    /// indices. Throws (or returns a short array) on failure — callers must
    /// not assume `result.count == texts.count`.
    func translateBatch(_ texts: [String]) async throws -> [String]
}

// ============================================================================
// MARK: - Chunked, timeout-bounded runner
// ============================================================================

public enum ChunkedTranslationRunner {

    public static let defaultChunkSize = 25
    public static let defaultChunkTimeout: TimeInterval = 6.0

    /// Splits `lines` into chunks of `chunkSize`, translates each chunk with
    /// `executor`, and invokes `onChunkComplete` once per chunk that lands
    /// within `chunkTimeout` — one dictionary (original-array index ->
    /// translated text) per successful chunk, so callers can do ONE
    /// @Published merge per chunk (never per line). A chunk that times out
    /// or throws is silently skipped; later chunks still run.
    ///
    /// Cooperative cancellation: checks `Task.isCancelled` between chunks so
    /// a song change mid-translation stops issuing new chunk requests.
    public static func run(
        lines: [String],
        chunkSize: Int = defaultChunkSize,
        chunkTimeout: TimeInterval = defaultChunkTimeout,
        executor: LyricsTranslationExecuting,
        onChunkComplete: ([Int: String]) -> Void
    ) async {
        guard !lines.isEmpty, chunkSize > 0 else { return }
        var start = 0
        while start < lines.count {
            if Task.isCancelled { return }
            let end = min(start + chunkSize, lines.count)
            let chunk = Array(lines[start..<end])
            let baseIndex = start
            start = end

            if let translated = await runChunkWithTimeout(chunk, timeout: chunkTimeout, executor: executor) {
                var mapped: [Int: String] = [:]
                for (offset, text) in translated.enumerated() where offset < chunk.count {
                    mapped[baseIndex + offset] = text
                }
                if !mapped.isEmpty {
                    onChunkComplete(mapped)
                }
            }
        }
    }

    /// Same as `run`, but first splits each line into script runs
    /// (`ScriptRunSegmenter`) so a mixed-script line (e.g. Hangul + Latin —
    /// see the 2026-09-20 NewJeans "How Sweet" evidence) gets EACH run
    /// translated as its own unit instead of one whole-line auto-detect call
    /// that only translates the dominant script.
    ///
    /// - Single-run lines (the overwhelming majority) take the EXACT SAME
    ///   path as `run` — unchanged behavior, same chunk-timeout semantics.
    /// - Multi-run lines route each run to the executor registered for its
    ///   `ScriptRunSegmenter.RunLanguage.localeIdentifier` in
    ///   `executorsByLanguage` (e.g. `"ko"` -> an explicit-source-Korean
    ///   session), falling back to `defaultExecutor` (`source: nil`, same as
    ///   today) for any language without a dedicated executor — including
    ///   `.unknown` runs. Runs for a given language are batched together
    ///   (one `run(...)` call per language actually present), matching how
    ///   the Translation framework needs one `TranslationSession`
    ///   (== one fixed source/target `Configuration`) per batch.
    /// - A multi-run line only reaches `onChunkComplete` once ALL of its
    ///   runs have translated; `ScriptRunSegmenter.reassemble` puts them
    ///   back in order under the line's original index.
    public static func runMultiScript(
        lines: [String],
        chunkSize: Int = defaultChunkSize,
        chunkTimeout: TimeInterval = defaultChunkTimeout,
        defaultExecutor: LyricsTranslationExecuting,
        executorsByLanguage: [String: LyricsTranslationExecuting] = [:],
        onChunkComplete: ([Int: String]) -> Void
    ) async {
        guard !lines.isEmpty else { return }

        var singleRunIndices: [Int] = []
        var multiRunLines: [(lineIndex: Int, runs: [ScriptRunSegmenter.Run])] = []
        for (index, line) in lines.enumerated() {
            let runs = ScriptRunSegmenter.segment(line)
            if runs.count <= 1 {
                singleRunIndices.append(index)
            } else {
                multiRunLines.append((index, runs))
            }
        }

        if !singleRunIndices.isEmpty {
            if Task.isCancelled { return }
            let singleLines = singleRunIndices.map { lines[$0] }
            await run(
                lines: singleLines,
                chunkSize: chunkSize,
                chunkTimeout: chunkTimeout,
                executor: defaultExecutor
            ) { localMapped in
                var remapped: [Int: String] = [:]
                for (localIndex, text) in localMapped {
                    remapped[singleRunIndices[localIndex]] = text
                }
                if !remapped.isEmpty { onChunkComplete(remapped) }
            }
        }

        guard !multiRunLines.isEmpty else { return }

        // Flatten every run across every multi-run line into per-language
        // submission lists, remembering each run's (line, ordinal) so
        // translated results can be routed back and reassembled in order.
        struct RunLocation { let lineIndex: Int; let ordinal: Int }
        var textsByLanguageKey: [String: [String]] = [:]
        var locationsByLanguageKey: [String: [RunLocation]] = [:]
        var runCountByLine: [Int: Int] = [:]
        for entry in multiRunLines {
            runCountByLine[entry.lineIndex] = entry.runs.count
            for (ordinal, run) in entry.runs.enumerated() {
                let key = run.language.localeIdentifier ?? "default"
                textsByLanguageKey[key, default: []].append(run.text)
                locationsByLanguageKey[key, default: []].append(RunLocation(lineIndex: entry.lineIndex, ordinal: ordinal))
            }
        }

        var translatedRunsByLine: [Int: [Int: String]] = [:]

        func emitCompletedLines() {
            guard !translatedRunsByLine.isEmpty else { return }
            var completed: [Int: String] = [:]
            for (lineIndex, runMap) in translatedRunsByLine {
                guard let total = runCountByLine[lineIndex], runMap.count == total else { continue }
                let ordered = (0..<total).compactMap { runMap[$0] }
                guard ordered.count == total else { continue }
                completed[lineIndex] = ScriptRunSegmenter.reassemble(ordered)
            }
            guard !completed.isEmpty else { return }
            for lineIndex in completed.keys { translatedRunsByLine.removeValue(forKey: lineIndex) }
            onChunkComplete(completed)
        }

        for (languageKey, texts) in textsByLanguageKey {
            if Task.isCancelled { return }
            let executor = executorsByLanguage[languageKey] ?? defaultExecutor
            let locations = locationsByLanguageKey[languageKey] ?? []
            await run(
                lines: texts,
                chunkSize: chunkSize,
                chunkTimeout: chunkTimeout,
                executor: executor
            ) { localMapped in
                for (localIndex, text) in localMapped {
                    guard localIndex < locations.count else { continue }
                    let location = locations[localIndex]
                    translatedRunsByLine[location.lineIndex, default: [:]][location.ordinal] = text
                }
                emitCompletedLines()
            }
        }
    }

    /// Races the real translation against a timeout sleep; returns nil on
    /// timeout OR on thrown error (both are "this chunk failed, move on").
    private static func runChunkWithTimeout(
        _ chunk: [String],
        timeout: TimeInterval,
        executor: LyricsTranslationExecuting
    ) async -> [String]? {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                try? await executor.translateBatch(chunk)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// ============================================================================
// MARK: - Per-process memoized language-pair availability
// ============================================================================

#if canImport(Translation)
@available(macOS 15.0, *)
public actor TranslationAvailabilityMemo {
    public static let shared = TranslationAvailabilityMemo()

    private var cache: [String: LanguageAvailability.Status] = [:]
    #if DEBUG
    private var checkCount = 0
    public var debugCheckCount: Int { checkCount }
    public func debugReset() {
        cache.removeAll()
        checkCount = 0
    }
    #endif

    /// One real `LanguageAvailability().status(...)` call per (source,
    /// target) pair for the life of the process; every subsequent call for
    /// the same pair returns the memoized result. This is what removes the
    /// per-song system availability check from the translation request path
    /// (audit fact (a)).
    public func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        let key = "\(source.languageCode?.identifier ?? "auto")->\(target.languageCode?.identifier ?? "?")"
        if let cached = cache[key] { return cached }
        #if DEBUG
        checkCount += 1
        #endif
        let status = await LanguageAvailability().status(from: source, to: target)
        cache[key] = status
        return status
    }
}

@available(macOS 15.0, *)
extension TranslationSession: LyricsTranslationExecuting {
    public func translateBatch(_ texts: [String]) async throws -> [String] {
        let requests = texts.map { TranslationSession.Request(sourceText: $0) }
        let responses = try await self.translations(from: requests)
        return responses.map { $0.targetText }
    }
}
#endif
