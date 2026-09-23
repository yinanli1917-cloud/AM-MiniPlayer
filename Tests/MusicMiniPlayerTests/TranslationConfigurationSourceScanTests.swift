import XCTest

/// Source-scan guard (2026-09-22 language-picker popup fix): EVERY
/// `TranslationSession.Configuration(...)` in Sources/ must carry an
/// explicit, non-nil `source:` argument. `source: nil` (or omitting `source:`
/// entirely, which defaults to nil) makes the Translation framework
/// re-detect the source PER BATCH -- any batch it cannot confidently
/// identify surfaces the system language-picker popup. This mirrors the
/// existing string-scan convention (see NativeLyricsSurfaceSourceTests) --
/// read the source as text, strip comments, and assert on the stripped body,
/// rather than exercising the (macOS 15+, on-device-model-dependent)
/// Translation framework itself.
final class TranslationConfigurationSourceScanTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Strips `//` line comments and `/* ... */` block comments (including
    /// doc comments) from Swift source so a `Configuration(source: nil, ...)`
    /// mentioned only in prose (as this very file's header does, and as
    /// LyricsService's fix-explanation comments do) never trips the scan.
    private func stripComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var chars = Array(source)
        var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    private func allSwiftSources() throws -> [(path: String, body: String)] {
        let sourcesRoot = repoRoot().appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate Sources/")
            return []
        }
        var results: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(of: repoRoot().path + "/", with: "")
            results.append((relativePath, stripComments(text)))
        }
        return results
    }

    /// Finds every `TranslationSession.Configuration(` call and captures the
    /// argument list up to its matching closing paren (balanced, so a
    /// `target: Locale.Language(identifier: "zh-Hans")` nested call doesn't
    /// prematurely close the outer scan).
    private func configurationCallArgumentLists(in body: String) -> [String] {
        var results: [String] = []
        let marker = "TranslationSession.Configuration("
        var searchRange = body.startIndex..<body.endIndex
        while let markerRange = body.range(of: marker, range: searchRange) {
            var depth = 1
            var index = markerRange.upperBound
            let start = index
            while index < body.endIndex, depth > 0 {
                if body[index] == "(" { depth += 1 }
                if body[index] == ")" { depth -= 1 }
                index = body.index(after: index)
            }
            let argsEnd = depth == 0 ? body.index(before: index) : index
            results.append(String(body[start..<argsEnd]))
            searchRange = index..<body.endIndex
        }
        return results
    }

    func test_everyTranslationConfigurationHasAnExplicitNonNilSource() throws {
        var violations: [String] = []
        var totalFound = 0

        for (path, body) in try allSwiftSources() {
            for args in configurationCallArgumentLists(in: body) {
                totalFound += 1
                // Must mention `source:` at all (bare `Configuration(target:)`
                // defaults source to nil, same failure mode as an explicit
                // `source: nil`).
                guard args.contains("source:") else {
                    violations.append("\(path): Configuration(\(args.trimmingCharacters(in: .whitespacesAndNewlines))) -- no `source:` argument at all (defaults to nil)")
                    continue
                }
                // The `source:` argument's value must not be the literal `nil`.
                if let sourceRange = args.range(of: "source:") {
                    let afterSource = args[sourceRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if afterSource.hasPrefix("nil") {
                        let charAfterNil = afterSource.dropFirst(3).first
                        // Guard against a hypothetical future identifier
                        // literally named `nilSomething` being misread as the
                        // `nil` literal -- only a following delimiter/end
                        // counts as the actual `nil` value.
                        if charAfterNil == nil || charAfterNil == "," || charAfterNil == ")" {
                            violations.append("\(path): Configuration(\(args.trimmingCharacters(in: .whitespacesAndNewlines))) -- source: nil")
                        }
                    }
                }
            }
        }

        XCTAssertGreaterThan(totalFound, 0, "Sanity check: the scan should find at least the known TranslationSession.Configuration call sites -- if this is 0, the scan itself is broken.")
        XCTAssertTrue(
            violations.isEmpty,
            "Every TranslationSession.Configuration(...) in Sources/ must carry an explicit, non-nil source (2026-09-22 language-picker popup fix):\n\(violations.joined(separator: "\n"))"
        )
    }
}
