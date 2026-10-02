/**
 * [INPUT]: Foundation (FileManager, ProcessInfo), NanoPodCacheLocation.ProcessIdentity (XCTest detection)
 * [OUTPUT]: Exports NanoPodLogLocation (where nanoPod's own always-on evidence logs live:
 *           `~/Library/Logs/nanoPod`, a temp directory under XCTest) — the onboarding tour's gesture trace writes
 *           `tour-gesture.log` there and the diagnostics report bundle attaches it.
 * [POS]: Utils — one seam so no test process can write the founder's real log directory.
 */

import Foundation

public enum NanoPodLogLocation {
    public static let tourGestureLogName = "tour-gesture.log"

    /// `~/Library/Logs/nanoPod` for the app; a per-process temp directory under XCTest.
    public static func directory() -> URL {
        if NanoPodCacheLocation.ProcessIdentity.current.isXCTest {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("nanoPod-test-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nanoPod", isDirectory: true)
    }

    /// The tour gesture trace's log and its one rotation backup (whichever exist).
    public static func tourGestureLogs(in directory: URL = NanoPodLogLocation.directory()) -> [URL] {
        [tourGestureLogName, tourGestureLogName + ".1"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
