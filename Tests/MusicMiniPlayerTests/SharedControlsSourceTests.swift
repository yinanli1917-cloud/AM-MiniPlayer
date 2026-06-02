import XCTest

final class SharedControlsSourceTests: XCTestCase {
    func testNativeProgressBarAnimatesHoverAndPassiveProgressTransitions() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedControlsURL = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift")
        let source = try String(contentsOf: sharedControlsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("nsView.prefersReducedMotion = reduceMotion"))
        XCTAssertTrue(source.contains("fillLayer.mask = fillMaskLayer"))
        XCTAssertTrue(source.contains("fillMaskLayer.backgroundColor = NSColor.black.cgColor"))
        XCTAssertTrue(source.contains("let hoverTransitionDuration: CFTimeInterval?"))
        XCTAssertTrue(source.contains("let progressTransitionDuration: CFTimeInterval?"))
        XCTAssertTrue(source.contains("guard externalDragPosition == nil else { return nil }"))
        XCTAssertTrue(source.contains("rect: progressInteractiveRect()"))
        XCTAssertTrue(source.contains("options: [.mouseEnteredAndExited, .activeAlways]"))
        XCTAssertFalse(source.contains(".inVisibleRect"))
        XCTAssertTrue(source.contains("private func progressInteractiveRect()"))
        XCTAssertTrue(source.contains("private func syncHoverStateToPointer()"))
        XCTAssertTrue(source.contains("guard progressInteractiveRect().contains(point) else"))
        XCTAssertTrue(source.contains("private func setProgressHovering(_ hovering: Bool)"))
        XCTAssertTrue(source.contains("CABasicAnimation(keyPath: \"bounds\")"))
        XCTAssertTrue(source.contains("CABasicAnimation(keyPath: \"position\")"))
        XCTAssertTrue(source.contains("CABasicAnimation(keyPath: \"cornerRadius\")"))
        XCTAssertTrue(source.contains("private func applyProgressMask("))
        XCTAssertTrue(source.contains("fillMaskLayer.frame = frame"))
    }
}
