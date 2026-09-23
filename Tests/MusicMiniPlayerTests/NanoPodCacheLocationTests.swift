/**
 * [INPUT]: MusicMiniPlayerCore NanoPodCacheLocation, LyricsDiskCache,
 *          MetadataDiskCache, TranslationDiskCache
 * [OUTPUT]: Scope resolution table, directory mapping, in-process isolation
 *           assertion, legacy-seed-without-clobber round trip, legacySeedURL
 *           injected-path guard
 * [POS]: Test module — pins the 2026-09-22 incident fix (a non-production
 *        process using default construction reading/writing the founder's
 *        real ~/Library/Application Support/nanoPod/ caches, and a
 *        schema-version mismatch discarding then overwriting the other
 *        schema's file).
 */

import XCTest
@testable import MusicMiniPlayerCore

final class NanoPodCacheLocationTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod_cache_location_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func identity(
        environment: [String: String] = [:],
        bundleIdentifier: String? = nil,
        infoNamespace: String? = nil,
        isXCTest: Bool = false,
        processName: String = "TestProcess",
        processID: Int32 = 4242
    ) -> NanoPodCacheLocation.ProcessIdentity {
        NanoPodCacheLocation.ProcessIdentity(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            infoNamespace: infoNamespace,
            isXCTest: isXCTest,
            processName: processName,
            processID: processID
        )
    }

    // MARK: - Scope table

    func test_scope_overrideWinsOverEverything() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            environment: [NanoPodCacheLocation.overrideEnvironmentKey: "/tmp/forced"],
            bundleIdentifier: NanoPodCacheLocation.productionBundleIdentifier,
            isXCTest: true
        ))
        XCTAssertEqual(scope, .override(path: "/tmp/forced"))
    }

    func test_scope_emptyOverrideValueIsIgnored() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            environment: [NanoPodCacheLocation.overrideEnvironmentKey: ""],
            isXCTest: true
        ))
        XCTAssertEqual(scope, .testRun, "an empty override value must not win — it falls through to the next rule")
    }

    func test_scope_xcTestProcess() {
        let scope = NanoPodCacheLocation.scope(for: identity(isXCTest: true))
        XCTAssertEqual(scope, .testRun)
    }

    func test_scope_productionBundleWithoutNamespace() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            bundleIdentifier: NanoPodCacheLocation.productionBundleIdentifier
        ))
        XCTAssertEqual(scope, .production)
    }

    func test_scope_productionBundleWithNamespaceIsIsolated() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            bundleIdentifier: NanoPodCacheLocation.productionBundleIdentifier,
            infoNamespace: "worktree-abc123"
        ))
        XCTAssertEqual(scope, .isolated(namespace: "worktree-abc123"))
    }

    func test_scope_otherBundleIdentifierIsIsolatedByBundleId() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            bundleIdentifier: "com.nanopod.edgecollapsespike"
        ))
        XCTAssertEqual(scope, .isolated(namespace: "com.nanopod.edgecollapsespike"))
    }

    func test_scope_nilBundleIdentifierFallsBackToProcessName() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            bundleIdentifier: nil,
            processName: "LyricsVerifier"
        ))
        XCTAssertEqual(scope, .isolated(namespace: "LyricsVerifier"))
    }

    func test_scope_namespaceIsSanitized() {
        let scope = NanoPodCacheLocation.scope(for: identity(
            bundleIdentifier: NanoPodCacheLocation.productionBundleIdentifier,
            infoNamespace: "a b/c"
        ))
        XCTAssertEqual(scope, .isolated(namespace: "a-b-c"))
    }

    // MARK: - Directory mapping

    func test_directory_production_isExactlyApplicationSupportSlashNanoPod() {
        let appSupport = URL(fileURLWithPath: "/fake/AppSupport", isDirectory: true)
        let dir = NanoPodCacheLocation.directory(
            for: .production,
            applicationSupport: appSupport,
            temporary: URL(fileURLWithPath: "/fake/tmp", isDirectory: true),
            processID: 1
        )
        XCTAssertEqual(dir.standardizedFileURL.path, appSupport.appendingPathComponent("nanoPod", isDirectory: true).standardizedFileURL.path)
    }

    func test_directory_isolated_isSiblingOfProductionDirectory_notInsideIt() {
        let appSupport = URL(fileURLWithPath: "/fake/AppSupport", isDirectory: true)
        let dir = NanoPodCacheLocation.directory(
            for: .isolated(namespace: "worktree-foo"),
            applicationSupport: appSupport,
            temporary: URL(fileURLWithPath: "/fake/tmp", isDirectory: true),
            processID: 1
        )
        XCTAssertEqual(dir.standardizedFileURL.path, appSupport.appendingPathComponent("nanoPod-dev/worktree-foo").standardizedFileURL.path)
        XCTAssertFalse(dir.path.contains("/nanoPod/"), "isolated must never live under the production nanoPod/ directory")
    }

    func test_directory_testRun_usesTemporaryDirectoryWithPID() {
        let temp = URL(fileURLWithPath: "/fake/tmp", isDirectory: true)
        let dir = NanoPodCacheLocation.directory(
            for: .testRun,
            applicationSupport: URL(fileURLWithPath: "/fake/AppSupport", isDirectory: true),
            temporary: temp,
            processID: 999
        )
        XCTAssertEqual(dir.standardizedFileURL.path, temp.appendingPathComponent("nanoPod-xctest-999").standardizedFileURL.path)
    }

    func test_directory_override_expandsTilde() {
        let dir = NanoPodCacheLocation.directory(
            for: .override(path: "~/nanopod-override-test"),
            applicationSupport: URL(fileURLWithPath: "/fake/AppSupport", isDirectory: true),
            temporary: URL(fileURLWithPath: "/fake/tmp", isDirectory: true),
            processID: 1
        )
        let expected = (("~/nanopod-override-test" as NSString).expandingTildeInPath)
        XCTAssertEqual(dir.path, expected)
        XCTAssertFalse(dir.path.hasPrefix("~"))
    }

    // MARK: - In-process isolation (this IS an XCTest process)

    func test_inProcess_resolvedDirectoryIsNotTheRealProductionDirectory() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.temporaryDirectory
        let realProductionDir = appSupport.appendingPathComponent("nanoPod", isDirectory: true)
        XCTAssertNotEqual(NanoPodCacheLocation.directory.standardizedFileURL.path, realProductionDir.standardizedFileURL.path)
    }

    func test_inProcess_defaultURLsAreNotUnderRealNanoPodDirectory_andCarrySchemaVersion() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.temporaryDirectory
        let realProductionDir = appSupport.appendingPathComponent("nanoPod", isDirectory: true).standardizedFileURL.path

        let lyricsURL = LyricsDiskCache.defaultURL()
        let metadataURL = MetadataDiskCache.defaultURL()
        let translationURL = TranslationDiskCache.defaultURL()

        for url in [lyricsURL, metadataURL, translationURL] {
            XCTAssertFalse(
                url.deletingLastPathComponent().standardizedFileURL.path == realProductionDir,
                "\(url.path) must not resolve into the real production nanoPod directory from an XCTest process"
            )
        }

        XCTAssertEqual(lyricsURL.lastPathComponent, "lyrics_cache.v\(LyricsDiskCache.schemaVersion).json")
        XCTAssertEqual(metadataURL.lastPathComponent, "metadata_cache.v\(MetadataDiskCache.schemaVersion).json")
        XCTAssertEqual(translationURL.lastPathComponent, "translation_cache.v\(TranslationDiskCache.schemaVersion).json")
    }

    // MARK: - Legacy seed + no clobber

    func test_lyricsDiskCache_seedsFromLegacyUnversionedFile_thenNeverWritesBackToIt() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("lyrics_cache.json")

        // Build the legacy (pre-versioning) file with one entry, same schema version.
        let seedWriter = LyricsDiskCache(fileURL: legacyURL)
        let seedLine = LyricLine(text: "legacy seed line", startTime: 1, endTime: 2)
        seedWriter.set(title: "Seed Song", artist: "Seed Artist", duration: 200, source: "NetEase", lines: [seedLine], matchedDurationDiff: 0.1)
        let legacyBytesBeforeMainUse = try? Data(contentsOf: legacyURL)
        XCTAssertNotNil(legacyBytesBeforeMainUse)

        let versionedURL = NanoPodCacheLocation.versionedFileURL(baseName: "lyrics_cache", schemaVersion: LyricsDiskCache.schemaVersion, in: dir)
        let mainCache = LyricsDiskCache(fileURL: versionedURL)

        XCTAssertNotNil(mainCache.get(title: "Seed Song", artist: "Seed Artist", duration: 200), "must seed from the legacy unversioned file on first read")

        // A subsequent write must persist to the versioned file only.
        let newLine = LyricLine(text: "fresh line", startTime: 3, endTime: 4)
        mainCache.set(title: "New Song", artist: "New Artist", duration: 150, source: "QQ", lines: [newLine], matchedDurationDiff: 0.1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: versionedURL.path))
        let legacyBytesAfter = try? Data(contentsOf: legacyURL)
        XCTAssertEqual(legacyBytesBeforeMainUse, legacyBytesAfter, "the legacy seed file must never be written to")
    }

    func test_lyricsDiskCache_legacyFileWithDifferentVersion_isNotLoaded_andIsLeftUntouched() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("lyrics_cache.json")

        let mismatchedEnvelope: [String: Any] = [
            "version": LyricsDiskCache.schemaVersion - 1,
            "entries": [String: Any]()
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: mismatchedEnvelope)
        try legacyData.write(to: legacyURL)

        let versionedURL = NanoPodCacheLocation.versionedFileURL(baseName: "lyrics_cache", schemaVersion: LyricsDiskCache.schemaVersion, in: dir)
        let mainCache = LyricsDiskCache(fileURL: versionedURL)
        XCTAssertNil(mainCache.get(title: "Anything", artist: "Anyone", duration: 100), "a version-mismatched legacy file must not be loaded")

        let newLine = LyricLine(text: "line", startTime: 0, endTime: 1)
        mainCache.set(title: "Song", artist: "Artist", duration: 100, source: "QQ", lines: [newLine], matchedDurationDiff: 0)

        let legacyBytesAfter = try Data(contentsOf: legacyURL)
        XCTAssertEqual(legacyBytesAfter, legacyData, "the mismatched-version legacy file must be left byte-identical")
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionedURL.path))
    }

    func test_translationDiskCache_seedsFromLegacyFile_thenNeverWritesBackToIt() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("translation_cache.json")

        let seedWriter = TranslationDiskCache(fileURL: legacyURL, persistDebounce: 0)
        let fp = TranslationDiskCache.fingerprint(firstRealLineSHA256: "seed", lineCount: 1)
        seedWriter.set(songKey: "seed|artist", targetLanguage: "zh-Hans", fingerprint: fp, lines: [0: "种子翻译"])
        seedWriter.flush()
        let legacyBytesBeforeMainUse = try? Data(contentsOf: legacyURL)
        XCTAssertNotNil(legacyBytesBeforeMainUse)

        let versionedURL = NanoPodCacheLocation.versionedFileURL(baseName: "translation_cache", schemaVersion: TranslationDiskCache.schemaVersion, in: dir)
        let mainCache = TranslationDiskCache(fileURL: versionedURL, persistDebounce: 0)

        let seeded = mainCache.get(songKey: "seed|artist", targetLanguage: "zh-Hans", fingerprint: fp)
        XCTAssertEqual(seeded?[0], "种子翻译", "must seed from the legacy unversioned file on first read")

        let fp2 = TranslationDiskCache.fingerprint(firstRealLineSHA256: "new", lineCount: 1)
        mainCache.set(songKey: "new|artist", targetLanguage: "ja", fingerprint: fp2, lines: [0: "こんにちは"])
        mainCache.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: versionedURL.path))
        let legacyBytesAfter = try? Data(contentsOf: legacyURL)
        XCTAssertEqual(legacyBytesBeforeMainUse, legacyBytesAfter, "the legacy seed file must never be written to")
    }

    // MARK: - legacySeedURL guard

    func test_legacySeedURL_returnsNilForArbitraryInjectedPath() {
        XCTAssertNil(NanoPodCacheLocation.legacySeedURL(
            for: URL(fileURLWithPath: "/tmp/foo.json"),
            baseName: "lyrics_cache",
            schemaVersion: 31
        ))
    }

    func test_legacySeedURL_returnsNilForDifferentSchemaVersionFilename() {
        XCTAssertNil(NanoPodCacheLocation.legacySeedURL(
            for: URL(fileURLWithPath: "/tmp/lyrics_cache.v30.json"),
            baseName: "lyrics_cache",
            schemaVersion: 31
        ))
    }

    func test_legacySeedURL_returnsSiblingForMatchingVersionedFilename() {
        let versioned = URL(fileURLWithPath: "/tmp/lyrics_cache.v31.json")
        let seed = NanoPodCacheLocation.legacySeedURL(for: versioned, baseName: "lyrics_cache", schemaVersion: 31)
        XCTAssertEqual(seed?.path, "/tmp/lyrics_cache.json")
    }
}
