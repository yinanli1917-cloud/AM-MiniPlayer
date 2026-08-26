/**
 * [INPUT]: Process environment (NANOPOD_E2E / NANOPOD_E2E_LOG / NANOPOD_E2E_STATUS) + call-site fields
 * [OUTPUT]: JSONL event log + latest status snapshot for machine-driven real-app e2e
 * [POS]: Utils; env-gated no-op in production. Never records unless NANOPOD_E2E=1 (or a test seam).
 * [PROTOCOL]: Keep the disabled path allocation-free; do not add per-frame callers
 */

import Foundation

/// Machine-readable e2e telemetry. Production launches never set `NANOPOD_E2E`,
/// so every public entry returns before date formatting or file I/O.
public enum E2EEventLog {

    public static let environmentEnabledKey = "NANOPOD_E2E"
    public static let environmentEventLogKey = "NANOPOD_E2E_LOG"
    public static let environmentStatusKey = "NANOPOD_E2E_STATUS"

    private static let lock = NSLock()
    private static var testingEnabled: Bool?
    private static var testingEventURL: URL?
    private static var testingStatusURL: URL?
    private static var sequence: Int = 0

    private static let writeQueue = DispatchQueue(
        label: "com.nanopod.e2e-event-log",
        qos: .utility
    )

    public static var isEnabled: Bool {
        lock.lock()
        let testing = testingEnabled
        lock.unlock()
        if let testing { return testing }
        return ProcessInfo.processInfo.environment[environmentEnabledKey] == "1"
    }

    public static func configureForTesting(enabled: Bool?, eventURL: URL?, statusURL: URL?) {
        lock.lock()
        testingEnabled = enabled
        testingEventURL = eventURL
        testingStatusURL = statusURL
        sequence = 0
        lock.unlock()
        flush()
    }

    public static func resetForTesting() {
        configureForTesting(enabled: nil, eventURL: nil, statusURL: nil)
    }

    /// Append one JSONL event. No-op when e2e is off.
    @inline(__always)
    public static func emit(_ event: String, _ fields: [String: String] = [:]) {
        guard isEnabled else { return }
        let now = Date()
        let tsMs = Int((now.timeIntervalSince1970 * 1000.0).rounded())
        let seq = nextSequence()
        writeQueue.async {
            var object: [String: Any] = [
                "ts": iso8601Millis(now),
                "ts_ms": tsMs,
                "seq": seq,
                "event": event
            ]
            for (key, value) in fields {
                object[key] = value
            }
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            append(line, to: eventURL())
        }
    }

    /// Overwrite the latest status snapshot. No-op when e2e is off.
    @inline(__always)
    public static func writeStatus(_ fields: [String: String]) {
        guard isEnabled else { return }
        let now = Date()
        let tsMs = Int((now.timeIntervalSince1970 * 1000.0).rounded())
        writeQueue.async {
            var object: [String: Any] = [
                "ts": iso8601Millis(now),
                "ts_ms": tsMs
            ]
            for (key, value) in fields {
                object[key] = value
            }
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            overwrite(data, to: statusURL())
        }
    }

    public static func flush() {
        writeQueue.sync {}
    }

    // MARK: - Internals

    private static func nextSequence() -> Int {
        lock.lock()
        sequence += 1
        let value = sequence
        lock.unlock()
        return value
    }

    private static func eventURL() -> URL {
        lock.lock()
        let testing = testingEventURL
        lock.unlock()
        if let testing { return testing }
        if let path = ProcessInfo.processInfo.environment[environmentEventLogKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/tmp/nanopod_e2e.jsonl")
    }

    private static func statusURL() -> URL {
        lock.lock()
        let testing = testingStatusURL
        lock.unlock()
        if let testing { return testing }
        if let path = ProcessInfo.processInfo.environment[environmentStatusKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/tmp/nanopod_e2e_status.json")
    }

    private static func iso8601Millis(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func append(_ line: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func overwrite(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// Combined lyrics + playback snapshot for the e2e harness to poll.
public enum E2EStatusDump {
    public static func writeCurrent() {
        guard E2EEventLog.isEnabled else { return }
        let work = {
            let lyrics = LyricsService.shared
            let music = MusicController.shared
            E2EEventLog.writeStatus([
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "title": music.currentTrackTitle,
                "artist": music.currentArtist,
                "position": String(format: "%.3f", music.currentTime),
                "duration": String(format: "%.3f", music.duration),
                "isPlaying": music.isPlaying ? "true" : "false",
                "page": String(describing: music.currentPage),
                "displayState": lyrics.displayState.e2eLabel,
                "lineCount": String(lyrics.lyrics.count),
                "hasTranslation": lyrics.hasTranslation ? "true" : "false",
                "isTranslating": lyrics.isTranslating ? "true" : "false",
                "isLoading": lyrics.isLoading ? "true" : "false",
                "error": lyrics.error ?? ""
            ])
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
