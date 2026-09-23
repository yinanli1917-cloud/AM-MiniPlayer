/**
 * [INPUT]: Foundation (FileManager, ProcessInfo, Bundle)
 * [OUTPUT]: Exports NanoPodCacheLocation (scope resolution + directory/file
 *           URL derivation for the on-disk caches) — LyricsDiskCache,
 *           MetadataDiskCache, TranslationDiskCache route their defaultURL()
 *           through this
 * [POS]: Utils — single seam that keeps every non-production process
 *        (XCTest, LyricsVerifier, worktree/dev builds, ad-hoc spikes) off the
 *        founder's real ~/Library/Application Support/nanoPod/ caches, and
 *        keeps two schema versions of the same binary from clobbering each
 *        other's cache file (2026-09-22: a spike running lyrics schema 30
 *        wiped the app's schema-31 cache because both wrote the same
 *        unversioned filename)
 */

import Foundation

public enum NanoPodCacheLocation {
    public static let productionBundleIdentifier = "com.yinanli.nanoPod"
    /// Explicit path override, wins over every other signal.
    public static let overrideEnvironmentKey = "NANOPOD_CACHE_DIR"
    /// Info.plist key. Presence (any non-empty string) marks this bundle as
    /// a dev build that must not touch the production cache directory.
    public static let namespaceInfoKey = "NPCacheNamespace"

    public enum Scope: Equatable {
        case override(path: String)
        case testRun
        case production
        case isolated(namespace: String)
    }

    public struct ProcessIdentity: Equatable {
        public var environment: [String: String]
        public var bundleIdentifier: String?
        public var infoNamespace: String?
        public var isXCTest: Bool
        public var processName: String
        public var processID: Int32

        public init(
            environment: [String: String],
            bundleIdentifier: String?,
            infoNamespace: String?,
            isXCTest: Bool,
            processName: String,
            processID: Int32
        ) {
            self.environment = environment
            self.bundleIdentifier = bundleIdentifier
            self.infoNamespace = infoNamespace
            self.isXCTest = isXCTest
            self.processName = processName
            self.processID = processID
        }

        public static var current: ProcessIdentity {
            let processInfo = ProcessInfo.processInfo
            let environment = processInfo.environment
            let isXCTest = NSClassFromString("XCTestCase") != nil
                || environment["XCTestConfigurationFilePath"] != nil
                || environment["XCTestSessionIdentifier"] != nil
            return ProcessIdentity(
                environment: environment,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                infoNamespace: Bundle.main.object(forInfoDictionaryKey: namespaceInfoKey) as? String,
                isXCTest: isXCTest,
                processName: processInfo.processName,
                processID: processInfo.processIdentifier
            )
        }
    }

    /// Pure. Precedence: override (non-empty env value) > testRun > production > isolated.
    public static func scope(for identity: ProcessIdentity) -> Scope {
        if let overridePath = identity.environment[overrideEnvironmentKey], !overridePath.isEmpty {
            return .override(path: overridePath)
        }
        if identity.isXCTest {
            return .testRun
        }
        let namespace = identity.infoNamespace?.trimmingCharacters(in: .whitespacesAndNewlines)
        if identity.bundleIdentifier == productionBundleIdentifier, namespace == nil || namespace!.isEmpty {
            return .production
        }
        let rawNamespace = (namespace?.isEmpty == false ? namespace : nil)
            ?? identity.bundleIdentifier
            ?? identity.processName
        return .isolated(namespace: sanitize(rawNamespace))
    }

    /// Pure.
    public static func directory(for scope: Scope, applicationSupport: URL, temporary: URL, processID: Int32) -> URL {
        switch scope {
        case .override(let path):
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        case .testRun:
            return temporary.appendingPathComponent("nanoPod-xctest-\(processID)", isDirectory: true)
        case .production:
            return applicationSupport.appendingPathComponent("nanoPod", isDirectory: true)
        case .isolated(let namespace):
            return applicationSupport
                .appendingPathComponent("nanoPod-dev", isDirectory: true)
                .appendingPathComponent(namespace, isDirectory: true)
        }
    }

    /// Resolved once per process from ProcessIdentity.current; creates the
    /// directory. Thread-safe (static let — Swift guarantees one-time
    /// lazy initialization).
    public static let directory: URL = {
        let identity = ProcessIdentity.current
        let resolvedScope = scope(for: identity)
        let fm = FileManager.default
        let applicationSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = directory(
            for: resolvedScope,
            applicationSupport: applicationSupport,
            temporary: fm.temporaryDirectory,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if resolvedScope != .production {
            FileHandle.standardError.write(Data("nanoPod: caches isolated at \(dir.path) (scope \(resolvedScope))\n".utf8))
        }
        return dir
    }()

    /// "<baseName>.v<schemaVersion>.json" inside `directory`.
    public static func versionedFileURL(baseName: String, schemaVersion: Int, in directory: URL = NanoPodCacheLocation.directory) -> URL {
        directory.appendingPathComponent("\(baseName).v\(schemaVersion).json")
    }

    /// If `fileURL` is exactly the versioned filename this baseName/schemaVersion
    /// would produce, returns the sibling pre-versioning file ("<baseName>.json")
    /// as a read-only seed candidate. Any other filename (e.g. an injected test
    /// path) never seeds, so tests stay isolated from stray legacy files.
    public static func legacySeedURL(for fileURL: URL, baseName: String, schemaVersion: Int) -> URL? {
        guard fileURL.lastPathComponent == "\(baseName).v\(schemaVersion).json" else { return nil }
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(baseName).json")
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let sanitized = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}
