/**
 * [INPUT]: The app's live NSApp.windows tree (to locate the mounted NativeLyricsSurfaceView)
 * [OUTPUT]: One-shot text dump of the active + previous row's visible text sublayers, appended to /tmp/nanopod_rowdump.txt
 * [POS]: MusicMiniPlayerCore diagnosis tool for the CJK trailing-word ghost follow-up — on-demand via nanopod://debug/rowdump, public entry point for MusicMiniPlayerAppKit's URL handler (NativeLyricsSurfaceView itself is internal to this module)
 */

import AppKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-09-18 follow-up to the CJK trailing-word ghost (research/repro-2026-09-17-
// lyrics-render-3c.md §CJK, mitigated by 59647e1 but the founder still reports seeing a
// doubled/ghosted glyph on strongly-emphasized CJK words): "强调词尤其 CJK 还是重影的方式实现
// 的". This is the founder's own on-demand evidence-collection entry point — the moment they
// see it on screen, they hit nanopod://debug/rowdump and get the exact layer tree (class,
// frame, opacity, string prefix, whether contents is a rasterized bitmap, shouldRasterize,
// transform) for the active row and the row right before it, the pair involved in every report
// so far. Deliberately available in EVERY build configuration, including plain release — same
// discipline NativeLyricsMaskTrace already established (finding a layer tree costs nothing
// when nobody asks for it; the founder cannot pass an environment variable when launching from
// Finder, and a bug report is exactly the moment a terminal is least likely to be open).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
/// Depth-first search for the (singular) mounted native lyrics surface across every app
/// window. `NativeLyricsSurfaceView` is `internal` to this module by design (it is wired
/// entirely through `LyricsView`'s own SwiftUI hosting, never referenced by name outside
/// MusicMiniPlayerCore) — this protocol (module-internal, NOT nested in the public enum below
/// — a nested `private` protocol cannot be conformed to from a different file) lets a
/// cross-module caller (MusicMiniPlayerAppKit's URL handler) trigger the dump without needing
/// to know the concrete type. `NativeLyricsSurfaceView` conforms to it via its existing
/// `rowDumpLines()` method (LyricsLayerRendererView.swift).
protocol RowDumpProvider {
    func rowDumpLines() -> [String]
}

public enum NativeLyricsRowDump {
    private static func findProvider(in view: NSView) -> RowDumpProvider? {
        if let provider = view as? RowDumpProvider { return provider }
        for subview in view.subviews {
            if let found = findProvider(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    public static func dump(to path: String = "/tmp/nanopod_rowdump.txt") {
        var lines = ["─── rowdump \(ISO8601DateFormatter().string(from: Date())) ───"]
        var found = false
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            if let provider = findProvider(in: root) {
                found = true
                lines += provider.rowDumpLines()
                break
            }
        }
        if !found {
            lines.append("(no mounted native lyrics surface found in any window)")
        }
        let block = lines.joined(separator: "\n") + "\n\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(block.utf8))
        handle.closeFile()
    }
}
