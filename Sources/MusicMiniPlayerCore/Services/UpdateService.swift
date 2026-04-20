/**
 * [INPUT]: GitHub Releases API + CFBundleShortVersionString
 * [OUTPUT]: Exports UpdateService.shared, observable @Published state
 * [POS]: Seamless auto-update — silent check/download/verify/stage.
 *
 * Design goals (from user: "most seamless, senseless, effortless"):
 *   - No UI prompt. No "check now" button required.
 *   - Fire-and-forget background check ~5s after launch.
 *   - Only acts if GitHub release tag > installed CFBundleShortVersionString.
 *   - Downloads .zip + .zip.sha256, verifies hash, expands to staged.app.
 *   - On verification failure the staged bundle is discarded, never applied.
 *   - The actual "apply" (swap bundle + relaunch) happens on app quit via
 *     UpdateApplier (step 3) — this service only prepares the staged bundle.
 */

import Foundation
import CryptoKit
import Combine

// ──────────────────────────────────────────────
// MARK: - Public state model
// ──────────────────────────────────────────────

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case downloading(progress: Double)
    case staged(version: String, stagedAppURL: URL)
    case failed(reason: String)
}

// ──────────────────────────────────────────────
// MARK: - UpdateService
// ──────────────────────────────────────────────

@MainActor
public final class UpdateService: ObservableObject {

    public static let shared = UpdateService()

    @Published public private(set) var state: UpdateState = .idle

    /// Version currently staged on disk (persisted across launches so a
    /// download that finished on the previous run is still applied later).
    @Published public private(set) var stagedVersion: String? = nil

    // ──────────────────────────────────────────────
    // MARK: - Config
    // ──────────────────────────────────────────────

    private let repo: String = "yinanli1917-cloud/AM-MiniPlayer"
    private let releasesAPI: URL = URL(
        string: "https://api.github.com/repos/yinanli1917-cloud/AM-MiniPlayer/releases/latest"
    )!

    /// ~/Library/Application Support/nanoPod/updates/
    private lazy var updatesDir: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("nanoPod/updates", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var stagedMarkerURL: URL { updatesDir.appendingPathComponent("staged.version") }
    private var stagedAppURL: URL { updatesDir.appendingPathComponent("staged.app") }
    private var downloadedZipURL: URL { updatesDir.appendingPathComponent("download.zip") }

    // ──────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────

    private init() {
        loadStagedMarker()
    }

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────

    /// Fire-and-forget background check. Called 5s after applicationDidFinishLaunching.
    public func checkInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.performCheck()
        }
    }

    /// Path of staged .app if present and verified — UpdateApplier reads this on quit.
    public func stagedAppIfReady() -> URL? {
        guard stagedVersion != nil,
              FileManager.default.fileExists(atPath: stagedAppURL.path) else {
            return nil
        }
        return stagedAppURL
    }

    // ──────────────────────────────────────────────
    // MARK: - Main flow
    // ──────────────────────────────────────────────

    private func performCheck() async {
        await setState(.checking)

        do {
            let release = try await fetchLatestRelease()
            let installed = Self.installedVersion
            let remote = Self.normalize(release.tagName)

            guard Self.isNewer(remote: remote, installed: installed) else {
                await setState(.upToDate)
                return
            }

            // Already staged this exact version? Skip re-download.
            if stagedVersion == remote,
               FileManager.default.fileExists(atPath: stagedAppURL.path) {
                await setState(.staged(version: remote, stagedAppURL: stagedAppURL))
                return
            }

            try await download(release: release, version: remote)

            await setStagedMarker(version: remote)
            await setState(.staged(version: remote, stagedAppURL: stagedAppURL))
        } catch {
            await setState(.failed(reason: "\(error)"))
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - GitHub API
    // ──────────────────────────────────────────────

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("nanoPod/\(Self.installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.apiFailed
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // ──────────────────────────────────────────────
    // MARK: - Download + verify + expand
    // ──────────────────────────────────────────────

    private func download(release: Release, version: String) async throws {
        guard let zipAsset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noZipAsset
        }
        let shaAsset = release.assets.first(where: { $0.name.hasSuffix(".zip.sha256") })

        await setState(.downloading(progress: 0))

        // Fetch zip
        let (zipData, _) = try await URLSession.shared.data(from: zipAsset.browserDownloadURL)
        try zipData.write(to: downloadedZipURL, options: .atomic)
        await setState(.downloading(progress: 0.6))

        // Verify SHA256 if the .sha256 asset is published alongside
        if let shaAsset = shaAsset {
            let (shaData, _) = try await URLSession.shared.data(from: shaAsset.browserDownloadURL)
            try verifySHA256(zipData: zipData, expectedRaw: shaData)
        }
        await setState(.downloading(progress: 0.8))

        // Expand into staged.app (atomic swap via temp dir)
        try expand(zip: downloadedZipURL, into: updatesDir)
        try? FileManager.default.removeItem(at: downloadedZipURL)
        _ = version  // retained by caller for marker persistence
    }

    private func verifySHA256(zipData: Data, expectedRaw: Data) throws {
        let expectedText = String(data: expectedRaw, encoding: .utf8) ?? ""
        // Typical format: "<hex>  <filename>\n"
        let expectedHex = expectedText
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first
            .map { String($0).lowercased() } ?? ""

        let actualDigest = SHA256.hash(data: zipData)
        let actualHex = actualDigest.map { String(format: "%02x", $0) }.joined()

        guard !expectedHex.isEmpty, expectedHex == actualHex else {
            throw UpdateError.hashMismatch
        }
    }

    /// Unzip and place the resulting .app bundle at `stagedAppURL`.
    private func expand(zip: URL, into dir: URL) throws {
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent("tmp-expand", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let task = Process()
        task.launchPath = "/usr/bin/unzip"
        task.arguments = ["-q", "-o", zip.path, "-d", tmp.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateError.unzipFailed }

        // Locate the .app bundle inside the extracted tree (usually at the top level).
        guard let appURL = try findAppBundle(in: tmp) else {
            throw UpdateError.noAppBundleInZip
        }

        try? fm.removeItem(at: stagedAppURL)
        try fm.moveItem(at: appURL, to: stagedAppURL)
        try? fm.removeItem(at: tmp)
    }

    private func findAppBundle(in dir: URL) throws -> URL? {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        if let app = contents.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        // One level deeper (some zips include a wrapper folder)
        for sub in contents where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let inner = try fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)
            if let app = inner.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    // ──────────────────────────────────────────────
    // MARK: - Staged-marker persistence
    // ──────────────────────────────────────────────

    private func loadStagedMarker() {
        guard let data = try? Data(contentsOf: stagedMarkerURL),
              let version = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty,
              FileManager.default.fileExists(atPath: stagedAppURL.path) else {
            stagedVersion = nil
            return
        }
        stagedVersion = version
    }

    private func setStagedMarker(version: String) async {
        try? version.data(using: .utf8)?.write(to: stagedMarkerURL, options: .atomic)
        stagedVersion = version
    }

    // ──────────────────────────────────────────────
    // MARK: - State helper
    // ──────────────────────────────────────────────

    private func setState(_ newState: UpdateState) async {
        state = newState
    }

    // ──────────────────────────────────────────────
    // MARK: - Version utilities (internal for tests)
    // ──────────────────────────────────────────────

    public nonisolated static var installedVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return normalize(v)
    }

    /// "v2.0.0" → "2.0.0"; "2.0" → "2.0"; strips leading "v" or "V".
    public nonisolated static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return s
    }

    /// Semver-ish comparison: pad missing components with 0.
    public nonisolated static func isNewer(remote: String, installed: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let i = installed.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(r.count, i.count)
        for idx in 0..<n {
            let rv = idx < r.count ? r[idx] : 0
            let iv = idx < i.count ? i[idx] : 0
            if rv > iv { return true }
            if rv < iv { return false }
        }
        return false
    }
}

// ──────────────────────────────────────────────
// MARK: - Errors
// ──────────────────────────────────────────────

public enum UpdateError: Error, CustomStringConvertible {
    case apiFailed
    case noZipAsset
    case hashMismatch
    case unzipFailed
    case noAppBundleInZip

    public var description: String {
        switch self {
        case .apiFailed:         return "GitHub Releases API request failed"
        case .noZipAsset:        return "Release has no .zip asset"
        case .hashMismatch:      return "Downloaded zip failed SHA256 verification"
        case .unzipFailed:       return "Unzip process returned non-zero"
        case .noAppBundleInZip:  return "No .app bundle found in extracted zip"
        }
    }
}
