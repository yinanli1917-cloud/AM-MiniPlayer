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
        XCTAssertTrue(source.contains("let hoverTransitionDuration: CFTimeInterval?"))
        XCTAssertTrue(source.contains("let progressTransitionDuration: CFTimeInterval?"))
        XCTAssertTrue(source.contains("guard externalDragPosition == nil else { return nil }"))
        XCTAssertTrue(source.contains("CABasicAnimation(keyPath: \"bounds\")"))
        XCTAssertTrue(source.contains("CABasicAnimation(keyPath: \"position\")"))
        XCTAssertTrue(source.contains("CABasicAnimation(keyPath: \"cornerRadius\")"))
    }
}
