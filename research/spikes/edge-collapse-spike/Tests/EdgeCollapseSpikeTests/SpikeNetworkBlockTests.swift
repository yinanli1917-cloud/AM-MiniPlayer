import XCTest
@testable import EdgeCollapseSpike

/// The spike must not reach the network (2026-09-22: itunes.apple.com rate
/// limit shared with another session's artwork measurements).
final class SpikeNetworkBlockTests: XCTestCase {
    override class func setUp() { SpikeNetworkBlock.install() }

    private func assertBlocked(_ session: URLSession, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await session.data(from: URL(string: "https://example.com/")!)
            XCTFail("request went out", file: file, line: line)
        } catch let e as URLError {
            XCTAssertEqual(e.code, .notConnectedToInternet, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func test_ephemeralSession_isBlocked() async { await assertBlocked(URLSession(configuration: .ephemeral)) }
    func test_defaultSession_isBlocked() async { await assertBlocked(URLSession(configuration: .default)) }
    func test_sharedSession_isBlocked() async { await assertBlocked(URLSession.shared) }
}
