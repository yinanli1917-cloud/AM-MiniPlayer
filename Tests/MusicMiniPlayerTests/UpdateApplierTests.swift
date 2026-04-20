// ──────────────────────────────────────────────
// UpdateApplierTests — verifies the generated apply.sh shell script
// actually swaps a dummy .app bundle end-to-end, using real mv/codesign.
// This is the critical verification: script syntax errors here would brick
// every user on update, so we exercise the real bash path.
// ──────────────────────────────────────────────

import XCTest
@testable import MusicMiniPlayerCore

final class UpdateApplierTests: XCTestCase {

    // MARK: - Script syntax smoke

    func testScriptBodyIsValidBash() {
        let script = UpdateApplier.scriptBody(
            pid: 999999,
            stagedPath: "/tmp/staged.app",
            destPath: "/tmp/dest.app",
            markerPath: "/tmp/marker",
            logPath: "/tmp/applier.log"
        )
        // bash -n does syntax check without execution
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applier_syntax_test.sh")
        try? script.write(to: tmp, atomically: true, encoding: .utf8)

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-n", tmp.path]
        let err = Pipe()
        task.standardError = err
        try? task.run()
        task.waitUntilExit()

        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(task.terminationStatus, 0, "bash -n reported: \(errText)")
    }

    // MARK: - Shell quoting handles paths with spaces

    func testPathsWithSpacesAreQuoted() {
        let script = UpdateApplier.scriptBody(
            pid: 1,
            stagedPath: "/tmp/with space/staged.app",
            destPath: "/tmp/dest.app",
            markerPath: "/tmp/m",
            logPath: "/tmp/l"
        )
        XCTAssertTrue(script.contains("'/tmp/with space/staged.app'"))
    }

    // MARK: - End-to-end dummy swap

    /// Create two dummy "bundles" (directories with a sentinel file inside),
    /// generate the script with pid=1 (init, always alive so wait loop exits
    /// by timeout), run it, and verify the destination now contains the
    /// staged bundle's content.
    func testRealBundleSwap() throws {
        let fm = FileManager.default
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applier_e2e_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let staged = sandbox.appendingPathComponent("staged.app", isDirectory: true)
        let dest = sandbox.appendingPathComponent("dest.app", isDirectory: true)
        let marker = sandbox.appendingPathComponent("marker")
        let log = sandbox.appendingPathComponent("applier.log")

        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try "NEW".write(to: staged.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try "OLD".write(to: dest.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        try "2.1.0".write(to: marker, atomically: true, encoding: .utf8)

        // Use a PID that's already dead so the wait loop exits immediately.
        // We spawn and reap a dummy process first.
        let dummy = Process()
        dummy.launchPath = "/usr/bin/true"
        try dummy.run()
        dummy.waitUntilExit()
        let deadPID = dummy.processIdentifier

        // Neuter the `open` + `codesign` + `/usr/bin/open` calls by running
        // the script with a PATH that shadows them — too invasive. Instead
        // we accept that codesign runs (harmless on a dummy bundle, it will
        // warn but not fail) and that `/usr/bin/open` fails on a dummy .app
        // (it returns non-zero but we don't check its exit code in the script).
        let script = UpdateApplier.scriptBody(
            pid: deadPID,
            stagedPath: staged.path,
            destPath: dest.path,
            markerPath: marker.path,
            logPath: log.path
        )
        let scriptURL = sandbox.appendingPathComponent("apply.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [scriptURL.path]
        try task.run()
        task.waitUntilExit()

        // Destination now holds NEW content
        let newVersion = try String(contentsOf: dest.appendingPathComponent("VERSION"), encoding: .utf8)
        XCTAssertEqual(newVersion, "NEW", "Bundle contents were not swapped")

        // Staged was consumed (moved, not copied)
        XCTAssertFalse(fm.fileExists(atPath: staged.path), "Staged bundle should have been moved away")

        // Marker removed
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "Staged marker should be cleaned up")

        // Log exists (diagnostic)
        XCTAssertTrue(fm.fileExists(atPath: log.path), "Log file should be written")
    }
}
