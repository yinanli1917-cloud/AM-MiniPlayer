/**
 * [INPUT]: E2EEventLog test seams (configureForTesting)
 * [OUTPUT]: Pins env-off silence, ISO-8601 millis JSONL, status overwrite, and flush visibility
 * [POS]: Test module for the real-app e2e telemetry sink
 */

import XCTest
@testable import MusicMiniPlayerCore

final class E2EEventLogTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-e2e-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        E2EEventLog.resetForTesting()
    }

    override func tearDownWithError() throws {
        E2EEventLog.resetForTesting()
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        try super.tearDownWithError()
    }

    func test_disabledByDefault_writesNothing() {
        let eventURL = scratch.appendingPathComponent("events.jsonl")
        let statusURL = scratch.appendingPathComponent("status.json")
        E2EEventLog.configureForTesting(enabled: false, eventURL: eventURL, statusURL: statusURL)

        E2EEventLog.emit("lyrics_applied", ["title": "should-not-appear"])
        E2EEventLog.writeStatus(["title": "should-not-appear"])
        E2EEventLog.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: eventURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))
        XCTAssertFalse(E2EEventLog.isEnabled)
    }

    func test_enabled_emitWritesISO8601MillisJSONL() throws {
        let eventURL = scratch.appendingPathComponent("events.jsonl")
        let statusURL = scratch.appendingPathComponent("status.json")
        E2EEventLog.configureForTesting(enabled: true, eventURL: eventURL, statusURL: statusURL)

        E2EEventLog.emit("fetch_start", [
            "title": "Stardust Night",
            "artist": "JADOES"
        ])
        E2EEventLog.flush()

        let raw = try String(contentsOf: eventURL, encoding: .utf8)
        let line = try XCTUnwrap(raw.split(separator: "\n").first).trimmingCharacters(in: .whitespaces)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        XCTAssertEqual(object["event"] as? String, "fetch_start")
        XCTAssertEqual(object["title"] as? String, "Stardust Night")
        XCTAssertEqual(object["artist"] as? String, "JADOES")
        XCTAssertEqual((object["seq"] as? NSNumber)?.intValue, 1)

        let ts = try XCTUnwrap(object["ts"] as? String)
        XCTAssertNotNil(
            ts.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,}Z$"#, options: .regularExpression),
            "ts must be UTC ISO-8601 with milliseconds, got \(ts)"
        )
        XCTAssertNotNil((object["ts_ms"] as? NSNumber)?.intValue)
    }

    func test_writeStatus_overwritesLatestSnapshot() throws {
        let eventURL = scratch.appendingPathComponent("events.jsonl")
        let statusURL = scratch.appendingPathComponent("status.json")
        E2EEventLog.configureForTesting(enabled: true, eventURL: eventURL, statusURL: statusURL)

        E2EEventLog.writeStatus(["title": "first", "displayState": "searching"])
        E2EEventLog.flush()
        E2EEventLog.writeStatus(["title": "女爵", "displayState": "content"])
        E2EEventLog.flush()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "女爵")
        XCTAssertEqual(object["displayState"] as? String, "content")
        XCTAssertNotNil(object["ts"] as? String)
        XCTAssertNotNil(object["ts_ms"] as? Int)
    }

    func test_displayState_e2eLabel_isStable() {
        XCTAssertEqual(LyricsDisplayState.searching.e2eLabel, "searching")
        XCTAssertEqual(LyricsDisplayState.deepSearching.e2eLabel, "deepSearching")
        XCTAssertEqual(LyricsDisplayState.content.e2eLabel, "content")
        XCTAssertEqual(LyricsDisplayState.noLyrics.e2eLabel, "noLyrics")
        XCTAssertEqual(LyricsDisplayState.networkUnreachable.e2eLabel, "networkUnreachable")
    }
}
