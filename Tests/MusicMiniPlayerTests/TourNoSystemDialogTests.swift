import XCTest

/// 铁律 5 (proposal §1): 引导自己不触发任何系统弹窗 — the ONLY thing allowed
/// to trigger the Automation permission dialog is
/// `OnboardingState.requestAutomationAccess()`, and it must only ever be
/// called from inside the "connect" step's button handler (a real click),
/// never from launch/detector/effect code. `automationStatus` (a read-only
/// query, `askUserIfNeeded: false`) is fine anywhere.
///
/// Same source-text-scan technique as `MenuBarMenuStructureTests`/
/// `SettingsWindowStructureTests` for structural properties that are easier
/// to pin by reading the file than by mocking a singleton system API.
final class TourNoSystemDialogTests: XCTestCase {
    private func sourceText(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            result.append(found)
            searchRange = found.upperBound..<haystack.endIndex
        }
        return result
    }

    /// Returns the name of the nearest enclosing top-level method above
    /// `index` — scans backward line by line for the last line indented
    /// exactly 4 spaces (an instance method, not a nested closure) starting
    /// with `func `/`private func `. `String.range(of:options:[.regularExpression,
    /// .backwards])` does NOT reliably return the rightmost match for a
    /// regex in this toolchain (verified empirically — it returned the
    /// FIRST match in the file instead), so this avoids it entirely.
    private func enclosingFunctionName(before index: String.Index, in source: String) -> String? {
        let prefix = source[source.startIndex..<index]
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            guard line.hasPrefix("    "), !line.hasPrefix("     ") else { continue } // exactly 4 spaces
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let withoutPrivate = trimmed.hasPrefix("private func ") ? String(trimmed.dropFirst("private func ".count)) : nil
            let withoutPlain = trimmed.hasPrefix("func ") ? String(trimmed.dropFirst("func ".count)) : nil
            guard let rest = withoutPrivate ?? withoutPlain else { continue }
            let name = rest.prefix(while: { $0.isLetter || $0.isNumber })
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    func test_requestAutomationAccess_onlyCalledFromConnectMusicHandler() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/Tour/TourController.swift")
        let calls = occurrences(of: "requestAutomationAccess()", in: source)
        XCTAssertEqual(calls.count, 1, "exactly one call site — any more risks one running outside a real click")
        guard let onlyCall = calls.first else { return }
        XCTAssertEqual(enclosingFunctionName(before: onlyCall.lowerBound, in: source), "connectMusic")
    }

    /// `connectMusic()` itself must only ever run from the primary-button
    /// handler (`handlePrimary()`'s `.step(.connect, _)` case) — never from
    /// `send`/`apply`/detector code, which would make it fire automatically.
    func test_connectMusic_onlyCalledFromThePrimaryButtonHandler() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/Tour/TourController.swift")
        // Exclude the function's own declaration line ("func connectMusic").
        let calls = occurrences(of: "connectMusic()", in: source).filter { range in
            let lineStart = source[..<range.lowerBound].lastIndex(of: "\n").map(source.index(after:)) ?? source.startIndex
            let line = source[lineStart..<range.upperBound]
            return !line.contains("func connectMusic")
        }
        XCTAssertEqual(calls.count, 1)
        guard let onlyCall = calls.first else { return }
        XCTAssertEqual(enclosingFunctionName(before: onlyCall.lowerBound, in: source), "handlePrimary")
    }

    /// `launchIfNeeded`/`requestTour`/`wireDetectors`/`send`/`apply` must
    /// never themselves reach `requestAutomationAccess` — spelled out
    /// explicitly since a future edit could route a NEW call through one of
    /// these without going through `connectMusic()`.
    func test_launchAndDetectorPaths_neverMentionRequestAutomationAccess() throws {
        let source = try sourceText("Sources/MusicMiniPlayerAppKit/Tour/TourController.swift")
        for functionName in ["launchIfNeeded", "requestTour", "wireDetectors", "handleDebugAction"] {
            guard let range = source.range(of: "func \(functionName)") else {
                return XCTFail("expected to find func \(functionName)")
            }
            // Scan to the next top-level `private func`/`func` at the same
            // indentation as a crude "end of function" delimiter.
            let rest = source[range.upperBound...]
            let nextFunc = rest.range(of: #"\n    (private )?func "#, options: .regularExpression)
            let body = nextFunc.map { rest[rest.startIndex..<$0.lowerBound] } ?? rest
            XCTAssertFalse(body.contains("requestAutomationAccess"), "\(functionName) must not call requestAutomationAccess directly")
        }
    }
}
