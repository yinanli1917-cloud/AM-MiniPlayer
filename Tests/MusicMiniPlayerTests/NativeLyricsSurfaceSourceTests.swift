import XCTest

final class NativeLyricsSurfaceSourceTests: XCTestCase {
    func testNativeSurfaceDoesNotHostSwiftUIRowViews() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surfaceURL = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift")
        let source = try String(contentsOf: surfaceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("NSHostingView"))
        XCTAssertFalse(source.contains("AnyView"))
        XCTAssertFalse(source.contains("LyricLineView("))
        XCTAssertTrue(source.contains("NativeLyricsRowView"))
        XCTAssertTrue(source.contains("CATextLayer"))
        XCTAssertTrue(source.contains("NativeLyricsFrameCadenceAccumulator"))
        XCTAssertTrue(source.contains("lyrics.nativeRenderer.summary"))
        XCTAssertTrue(source.contains("lyrics.nativeRenderer.configure"))
        XCTAssertTrue(source.contains("private func visibleRows(for configuration: LyricsLayerRendererConfiguration)"))
        XCTAssertTrue(source.contains("override func scrollWheel(with event: NSEvent)"))
        XCTAssertTrue(source.contains("NativeLyricsManualScrollState"))
        XCTAssertTrue(source.contains("handleNativeLineTap"))
        XCTAssertTrue(source.contains("mainSweepMaskLayer"))
        XCTAssertTrue(source.contains("mainPerRunSweepMaskLayer"))
        XCTAssertTrue(source.contains("updatePerRunSweepMask"))
        XCTAssertTrue(source.contains("translationSweepMaskLayer"))
        XCTAssertTrue(source.contains("lyricRenderTime()"))
        XCTAssertFalse(source.contains("fallback: configuration.lineTargetIndices[row.index]"))
        XCTAssertFalse(source.contains("wordFillBucket"))
    }
}
