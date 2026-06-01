//
//  RapidSwitchTests.swift
//  Covers the three primitives added for rapid switching and radio artwork fixes:
//    - SBTimeoutRunner: hard timeout releases blocked ScriptingBridge calls
//    - OBJCCatch:        converts Swift-uncatchable NSException into nil
//    - artworkCacheKey:  unified cache key (persistentID vs "radio:title|artist")
//
//  Note: the full end-to-end path depends on Music.app and network access, so it
//  cannot run in CI. These tests cover the new primitives that make the fix safe.
//

import XCTest
import Foundation
import AppKit
import SQLite3
@testable import MusicMiniPlayerCore
import ObjCSupport

final class RapidSwitchTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - SBTimeoutRunner
    // ------------------------------------------------------------------

    /// A fast block should return its value immediately.
    func testTimeoutRunnerReturnsValueOnFastBlock() {
        let start = Date()
        let result = SBTimeoutRunner.run(timeout: 1.0) { () -> Int? in
            return 42
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, 42)
        XCTAssertLessThan(elapsed, 0.2, "fast block should return immediately")
    }

    /// A timed-out block must return nil within the timeout window, not block the caller forever.
    ///
    /// The `ZZZ` prefix forces this test to run LAST alphabetically within
    /// this class. The queue is now SERIAL (to prevent concurrent AE crash),
    /// so a 5-second hung block would otherwise block tests that come after
    /// it alphabetically (see rapid-switch SBTimeoutRunner.swift comment).
    /// Running this test last means its hung background block can drain
    /// without delaying other assertions.
    func testTimeoutRunnerZZZReturnsNilOnHangingBlock() {
        let start = Date()
        let result = SBTimeoutRunner.run(timeout: 0.3) { () -> Int? in
            Thread.sleep(forTimeInterval: 5.0)  // Simulate wedged ScriptingBridge IPC.
            return 42
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "hanging block must time out to nil")
        XCTAssertLessThan(elapsed, 1.0, "caller must release within timeout window (got \(elapsed)s)")
    }

    /// A block returning nil is not a timeout; the caller should receive nil quickly.
    func testTimeoutRunnerPassesThroughNilResult() {
        let start = Date()
        let result = SBTimeoutRunner.run(timeout: 1.0) { () -> Int? in return nil }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.2)
    }

    /// Multiple concurrent fast calls sharing one worker queue should not block each other.
    func testTimeoutRunnerHandlesConcurrentCalls() {
        let group = DispatchGroup()
        var results: [Int] = []
        let lock = NSLock()

        for i in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                if let v: Int = SBTimeoutRunner.run(timeout: 1.0, { i }) {
                    lock.lock(); results.append(v); lock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(results.sorted(), Array(0..<10))
    }

    /// A hung non-Music lane must not block an independent test lane.
    /// Production Music read lanes are grouped separately by the source guard below.
    func testTimeoutRunnerLaneIsolationBypassesHungLane() {
        DispatchQueue.global().async {
            let _: Int? = SBTimeoutRunner.run(timeout: 0.2, lane: "test-hung-artwork") {
                Thread.sleep(forTimeInterval: 3.0)
                return 1
            }
        }

        Thread.sleep(forTimeInterval: 0.05)
        let start = Date()
        let result: Int? = SBTimeoutRunner.run(timeout: 0.5, lane: "test-position-poll") {
            return 2
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, 2)
        XCTAssertLessThan(elapsed, 0.2, "independent lanes should not wait behind a hung lane")
    }

    func testProductionMusicReadLanesShareCrashSafeWorkerGroup() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/Utils/SBTimeoutRunner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private static let musicReadLane = \"musicRead\""))
        for lane in ["positionPoll", "queueSnapshot", "stateSync", "trackMetadata"] {
            XCTAssertTrue(source.contains("\"\(lane)\""))
        }
        XCTAssertTrue(source.contains("musicReadLanes.contains(lane) ? musicReadLane : lane"))
    }

    func testPositionPollTimeoutCooldownBacksOffRepeatedTimeouts() {
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 1), 12.0)
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 2), 30.0)
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 3), 90.0)
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 10), 90.0)
        XCTAssertEqual(MusicController.positionPollFallbackMinInterval, 20.0)
    }

    func testProductionScriptingBridgeTimeoutCallsUseExplicitLanes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/MusicMiniPlayerCore/Services/MusicController.swift",
            "Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift",
            "Sources/MusicMiniPlayerCore/Services/MusicController+Artwork.swift"
        ]

        var offenders: [String] = []
        for path in files {
            let url = repoRoot.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8)
            for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated()
            where line.contains("SBTimeoutRunner.run(timeout:") && !line.contains("lane:") {
                offenders.append("\(path):\(lineIndex + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Production ScriptingBridge calls must choose an explicit timeout lane to avoid shared-lane starvation: \(offenders.joined(separator: "; "))"
        )
    }

    func testMusicTrackClassNameMapsAppleEventDescriptorCodes() {
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'cURL'>"), "URL track")
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'cFlT'>"), "file track")
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'cShT'>"), "shared track")
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'abcd'>"), "")
    }

    // ------------------------------------------------------------------
    // MARK: - OBJCCatch
    // ------------------------------------------------------------------

    /// A normally executed block should return nil, meaning no exception occurred.
    func testObjCCatchReturnsNilOnNormalExecution() {
        var ran = false
        let ex = OBJCCatch { ran = true }
        XCTAssertNil(ex)
        XCTAssertTrue(ran)
    }

    /// NSException must be captured and returned instead of crashing the process.
    /// This is the real crash pattern when SBElementArray mutates during Music.app iteration.
    func testObjCCatchCapturesNSException() {
        let ex = OBJCCatch {
            NSException(
                name: .rangeException,
                reason: "simulated mid-iteration mutation",
                userInfo: nil
            ).raise()
        }
        XCTAssertNotNil(ex)
        XCTAssertEqual(ex?.name, .rangeException)
        XCTAssertEqual(ex?.reason, "simulated mid-iteration mutation")
    }

    // ------------------------------------------------------------------
    // MARK: - artworkCacheKey
    // ------------------------------------------------------------------

    /// Non-empty persistentID is used directly as the key, preserving library-track behavior.
    func testCacheKeyUsesPersistentIDWhenNonEmpty() {
        let c = MusicController.shared
        let key = c.artworkCacheKey(persistentID: "ABC123", title: "Song", artist: "Artist")
        XCTAssertEqual(key, "ABC123" as NSString)
    }

    /// Empty persistentID returns nil, so radio artwork is not cached and is fetched each time.
    /// Previous code used "radio:title|artist", causing different songs with the same title/artist
    /// to hit stale artwork.
    func testCacheKeyReturnsNilForEmptyPersistentID() {
        let c = MusicController.shared
        XCTAssertNil(c.artworkCacheKey(persistentID: "", title: "Song Name", artist: "Artist Name"))
        XCTAssertNil(c.artworkCacheKey(persistentID: "", title: "", artist: "A"))
        XCTAssertNil(c.artworkCacheKey(persistentID: "", title: "Song", artist: ""))
    }

    func testMetadataArtworkCacheKeyUsesTrackIdentityBeforePersistentIDBackfill() {
        let c = MusicController.shared
        let key = c.artworkMetadataCacheKey(title: "戀愛預告", artist: "Sandy Lamb", album: "My Lovely Legend")
        XCTAssertEqual(key, "meta:恋爱预告|sandy lamb|my lovely legend" as NSString)
        XCTAssertNil(c.artworkMetadataCacheKey(title: "", artist: "Sandy Lamb", album: "My Lovely Legend"))
        XCTAssertNil(c.artworkMetadataCacheKey(title: "戀愛預告", artist: "", album: "My Lovely Legend"))
        XCTAssertNil(c.artworkMetadataCacheKey(title: "戀愛預告", artist: "Sandy Lamb", album: ""))
    }

    func testMetadataArtworkCacheKeyAllowsURLTracksWhenAlbumDisambiguates() {
        let c = MusicController(preview: true)
        c.currentTrackIsURLTrack = true

        let key = c.artworkMetadataCacheKey(title: "Warm On a Cold Night", artist: "HONNE", album: "Warm On a Cold Night")

        XCTAssertEqual(key, "meta:warm on a cold night|honne|warm on a cold night" as NSString)
        XCTAssertNil(c.artworkMetadataCacheKey(title: "Warm On a Cold Night", artist: "HONNE", album: ""))
    }

    func testArtworkCacheMissKeepsPreviousArtworkBrieflyUntilReplacement() async throws {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Tout tout"
        c.currentArtist = "Miel De Montagne & Blasé"
        c.currentArtwork = NSImage(size: NSSize(width: 12, height: 12))
        c.currentArtworkIsPlaceholder = false
        c.appliedArtworkGeneration = 0
        let generation = c.incrementGeneration()

        c.fetchArtwork(
            for: "Tout tout",
            artist: "Miel De Montagne & Blasé",
            album: "Ouin Ouin Ouin (Deluxe Edition)",
            persistentID: "",
            generation: generation
        )

        XCTAssertNotNil(c.currentArtwork)
        XCTAssertNotEqual(c.appliedArtworkGeneration, generation)

        try await Task.sleep(nanoseconds: MusicController.retainedArtworkPlaceholderGraceNanoseconds + 250_000_000)

        XCTAssertNotNil(c.currentArtwork)
        XCTAssertEqual(c.appliedArtworkGeneration, generation)
        XCTAssertTrue(c.currentArtworkIsPlaceholder)
        XCTAssertFalse(c.hasAppliedRealArtwork(for: generation))
    }

    func testInitialPlaceholderDoesNotCountAsRealArtworkForGeneration() async throws {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Missing Cover"
        c.currentArtist = "Diagnostics"
        c.currentAlbum = "Debug Album"
        c.currentArtwork = nil
        c.currentArtworkIsPlaceholder = false
        let generation = c.incrementGeneration()

        c.fetchArtwork(
            for: "Missing Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            persistentID: "",
            generation: generation
        )

        XCTAssertNotNil(c.currentArtwork)
        XCTAssertEqual(c.appliedArtworkGeneration, generation)
        XCTAssertTrue(c.currentArtworkIsPlaceholder)
        XCTAssertFalse(c.hasAppliedRealArtwork(for: generation))

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(c.currentArtworkIsPlaceholder)
        XCTAssertFalse(c.hasAppliedRealArtwork(for: generation))
    }

    func testWebArtworkApplyCachesMetadataKeyInMemory() async {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Airport in 10:30"
        c.currentArtist = "David Tao"
        c.currentAlbum = "David Tao"
        let generation = c.incrementGeneration()
        let image = NSImage(size: NSSize(width: 80, height: 80))

        await c.applyArtworkIfCurrent(
            image,
            persistentID: "",
            title: "Airport in 10:30",
            artist: "David Tao",
            album: "David Tao",
            generation: generation,
            source: .web
        )

        let key = c.artworkMetadataCacheKey(title: "Airport in 10:30", artist: "David Tao", album: "David Tao")
        XCTAssertNotNil(key)
        XCTAssertNotNil(c.artworkCache.object(forKey: key!))
    }

    func testAppleAuthoritativeArtworkCanReplaceWebFallbackForSameGeneration() async {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Late Apple Cover"
        c.currentArtist = "Diagnostics"
        c.currentAlbum = "Debug Album"
        let generation = c.incrementGeneration()
        let web = NSImage(size: NSSize(width: 80, height: 80))
        let apple = NSImage(size: NSSize(width: 120, height: 120))

        await c.applyArtworkIfCurrent(
            web,
            persistentID: "",
            title: "Late Apple Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            generation: generation,
            source: .web
        )
        await c.applyArtworkIfCurrent(
            apple,
            persistentID: "",
            title: "Late Apple Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            generation: generation,
            source: .playbackSession
        )

        XCTAssertEqual(c.currentArtwork?.size, NSSize(width: 120, height: 120))
        XCTAssertEqual(c.appliedArtworkGeneration, generation)
    }

    func testPlaybackSessionArtworkURLTrimsBinaryTailAfterConcreteImagePath() {
        let text = "title Unforgettable artist Nat King Cole https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/4e920b65-26fe-c608-d4a0-605cb1cfeca9/16UMGIM31150.rgb.jpg/800x800bb.jpg\u{fffd}\u{0005}more"

        let url = PlaybackSessionArtworkFetcher.firstAppleArtworkURL(in: text)

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/4e920b65-26fe-c608-d4a0-605cb1cfeca9/16UMGIM31150.rgb.jpg/800x800bb.jpg"
        )
    }

    func testPlaybackSessionArtworkURLNormalizesTemplatePath() {
        let text = #"{"artwork":{"url":"https:\/\/is1-ssl.mzstatic.com\/image\/thumb\/Music115\/v4\/3c\/0f\/75\/cover.jpg\/{w}x{h}bb.{f}"}}"#

        let url = PlaybackSessionArtworkFetcher.firstAppleArtworkURL(in: text)

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/3c/0f/75/cover.jpg/800x800bb.jpg"
        )
    }

    func testArtworkDiskCacheEncodingUsesCompressedJPEG() throws {
        let image = NSImage(size: NSSize(width: 600, height: 600))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 600).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 120, y: 120, width: 360, height: 360).fill()
        image.unlockFocus()

        let encoded = try XCTUnwrap(encodedArtworkDiskCacheData(from: image))
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        XCTAssertEqual(encoded.prefix(2), Data([0xff, 0xd8]))
        XCTAssertLessThan(encoded.count, tiff.count / 4)
    }

    func testArtworkDiskCachePrunesByByteBudgetAndRecency() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-artwork-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<6 {
            let url = root.appendingPathComponent("artwork-\(index).jpg")
            try Data(repeating: UInt8(index), count: 1024).write(to: url)
            let date = Date(timeIntervalSince1970: TimeInterval(index))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        pruneArtworkDiskCache(in: root, maxBytes: 4 * 1024, targetBytes: 3 * 1024, maxFiles: 4)

        let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let names = Set(remaining.map(\.lastPathComponent))
        let totalBytes = try remaining.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }

        XCTAssertLessThanOrEqual(totalBytes, 3 * 1024)
        XCTAssertEqual(names, ["artwork-3.jpg", "artwork-4.jpg", "artwork-5.jpg"])
    }

    func testPlaybackSessionArtworkTextMatchHandlesBinaryPayloadWithoutWholeBlobNormalization() {
        let binaryTail = String(repeating: "\u{fffd}\u{0005}\u{0000}", count: 2000)
        let text = "Plastic Love \u{0000} Palette:eillB https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/ef/ea/df/cover.jpg/800x800bb.jpg\(binaryTail)"

        XCTAssertTrue(
            PlaybackSessionArtworkFetcher.textMatches(
                text,
                title: "Plastic Love",
                artist: "eill",
                album: "Palette"
            )
        )
    }

    func testPlaybackSessionArtworkTextMatchUsesLatinizedCJKArtistAlias() {
        let text = "REALIZE 孫燕姿 https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg"

        XCTAssertTrue(
            PlaybackSessionArtworkFetcher.textMatches(
                text,
                title: "Realize",
                artist: "Yanzi Sun",
                album: "My Desired Happiness"
            )
        )
    }

    func testPlaybackSessionArtworkTextMatchUsesPercentEncodedNativeTitle() {
        let text = #"{"url":"https:\/\/music.apple.com\/cn\/album\/%E9%9B%A8%E7%88%B1\/347295255?i=347295290","albumName":"Rainie & Love?","artistName":"Rainie Yang","artwork":{"url":"https:\/\/is1-ssl.mzstatic.com\/image\/thumb\/Music\/bc\/e0\/e5\/mzi.mzfgcpgj.jpg\/{w}x{h}bb.{f}"}}"#

        XCTAssertTrue(
            PlaybackSessionArtworkFetcher.textMatches(
                text,
                title: "雨愛",
                artist: "Rainie Yang",
                album: "Rainie & Love?"
            )
        )
    }

    func testPlaybackSessionArtworkPollsUntilArchiveAppears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-playback-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lookup = Task {
            await PlaybackSessionArtworkFetcher.latestArtworkURLPolling(
                title: "Lovers",
                artist: "Li Ronghao",
                album: "Lovers - Single",
                root: root,
                retryFor: 0.6,
                pollInterval: 0.05
            )
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        try writePlaybackSessionArchive(
            root: root,
            payload: "Lovers Lovers - Single Li Ronghao https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4d/96/d6/cover.jpg/800x800bb.jpg"
        )

        let url = await lookup.value
        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4d/96/d6/cover.jpg/800x800bb.jpg"
        )
    }

    func testPlaybackSessionArtworkCacheReadsFilesystemBackedMusicUICache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-artwork-cache-\(UUID().uuidString)")
        let fsRoot = root.appendingPathComponent("fsCachedData")
        try FileManager.default.createDirectory(at: fsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("Cache.db")
        let fileName = "9E680B2E-C61A-459C-9D11-A3300AE98EE8"
        let expected = Data([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43])
        try expected.write(to: fsRoot.appendingPathComponent(fileName))
        try createMusicUICacheFixture(
            dbURL: dbURL,
            requestKey: "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg",
            fileName: fileName
        )

        let data = PlaybackSessionArtworkFetcher.cachedArtworkData(
            for: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg")!,
            cacheRoot: root
        )

        XCTAssertEqual(data, expected)
    }

    func testPlaybackSessionArtworkCacheBuildsImageFromMusicUICache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-artwork-cache-image-\(UUID().uuidString)")
        let fsRoot = root.appendingPathComponent("fsCachedData")
        try FileManager.default.createDirectory(at: fsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("Cache.db")
        let requestKey = "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg"
        let fileName = "D7A55A62-2B6A-4D3A-A4D7-0E0B8E437CE8"
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        bitmap?.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        guard let imageData = bitmap?.representation(using: .png, properties: [:]) else {
            return XCTFail("expected test image data")
        }
        try imageData.write(to: fsRoot.appendingPathComponent(fileName))
        try createMusicUICacheFixture(dbURL: dbURL, requestKey: requestKey, fileName: fileName)

        let image = PlaybackSessionArtworkFetcher.cachedArtworkImage(
            for: URL(string: requestKey)!,
            cacheRoot: root
        )

        XCTAssertEqual(image?.size, NSSize(width: 2, height: 2))
    }

    private func writePlaybackSessionArchive(root: URL, payload: String) throws {
        let archive = root.appendingPathComponent("IT-999999.playbackSessionArchive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let rawURL = archive.appendingPathComponent("contentItem.protobuf")
        try Data(payload.utf8).write(to: rawURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", rawURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let gzipped = output.fileHandleForReading.readDataToEndOfFile()
        try gzipped.write(to: archive.appendingPathComponent("contentItem.protobuf.gz"))
        try? FileManager.default.removeItem(at: rawURL)
    }

    private func createMusicUICacheFixture(dbURL: URL, requestKey: String, fileName: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, version INTEGER, hash_value INTEGER, storage_policy INTEGER, request_key TEXT UNIQUE, time_stamp NOT NULL DEFAULT CURRENT_TIMESTAMP, partition TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response(entry_ID, request_key) VALUES (1, '\(requestKey)');
        INSERT INTO cfurl_cache_receiver_data(entry_ID, isDataOnFS, receiver_data) VALUES (1, 1, '\(fileName)');
        """
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, schema, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            XCTFail(message)
        }
    }

    func testArtworkBackgroundToneMapDarkensBrightArtwork() {
        let dark = ArtworkBackgroundToneMap.forLuminance(0.1)
        let mid = ArtworkBackgroundToneMap.forLuminance(0.45)
        let bright = ArtworkBackgroundToneMap.forLuminance(0.9)

        XCTAssertGreaterThan(bright.shadeOpacity, mid.shadeOpacity)
        XCTAssertGreaterThanOrEqual(bright.shadeOpacity, 0.25)
        XCTAssertLessThanOrEqual(bright.shadeOpacity, 0.36)
        XCTAssertGreaterThan(bright.textureDimmingOpacity, mid.textureDimmingOpacity)
        XCTAssertLessThanOrEqual(bright.textureDimmingOpacity, 0.14)
        XCTAssertGreaterThan(dark.liftOpacity, mid.liftOpacity)
        XCTAssertLessThanOrEqual(dark.liftOpacity, 0.075)
    }

    func testArtworkBackgroundToneMapUsesHighlightPressureNotJustAverage() {
        let flatMid = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.45,
            shadowLuminance: 0.36,
            highlightLuminance: 0.54,
            luminanceSpread: 0.18,
            averageSaturation: 0.10
        ))
        let whiteCover = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.62,
            shadowLuminance: 0.42,
            highlightLuminance: 0.98,
            luminanceSpread: 0.56,
            averageSaturation: 0.08
        ))

        XCTAssertGreaterThan(whiteCover.shadeOpacity, flatMid.shadeOpacity)
        XCTAssertGreaterThan(whiteCover.textureSaturation, flatMid.textureSaturation)
        XCTAssertLessThan(whiteCover.textureBrightness, flatMid.textureBrightness)
    }

    func testArtworkBackgroundToneMapCompressesOversaturatedArtwork() {
        let balancedRed = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.42,
            shadowLuminance: 0.24,
            highlightLuminance: 0.64,
            luminanceSpread: 0.40,
            averageSaturation: 0.35
        ))
        let oversaturatedRed = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.42,
            shadowLuminance: 0.24,
            highlightLuminance: 0.64,
            luminanceSpread: 0.40,
            averageSaturation: 0.95
        ))

        XCTAssertLessThan(oversaturatedRed.textureSaturation, balancedRed.textureSaturation)
        XCTAssertLessThanOrEqual(oversaturatedRed.textureSaturation, 0.92)
        XCTAssertLessThan(oversaturatedRed.textureContrast, balancedRed.textureContrast)
        XCTAssertGreaterThan(oversaturatedRed.textureDimmingOpacity, balancedRed.textureDimmingOpacity)
    }

    func testArtworkBackgroundToneMapLiftsDarkArtworkWithoutFlattening() {
        let mid = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.42,
            shadowLuminance: 0.24,
            highlightLuminance: 0.62,
            luminanceSpread: 0.38,
            averageSaturation: 0.45
        ))
        let dark = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.12,
            shadowLuminance: 0.04,
            highlightLuminance: 0.32,
            luminanceSpread: 0.28,
            averageSaturation: 0.45
        ))

        XCTAssertGreaterThan(dark.liftOpacity, mid.liftOpacity)
        XCTAssertGreaterThanOrEqual(dark.liftOpacity, 0.05)
        XCTAssertLessThanOrEqual(dark.liftOpacity, 0.075)
        XCTAssertGreaterThan(dark.textureBrightness, mid.textureBrightness)
        XCTAssertGreaterThanOrEqual(dark.textureContrast, 1.02)
    }

    // ------------------------------------------------------------------
    // MARK: - artwork candidate matching
    // ------------------------------------------------------------------

    func testArtworkCandidateRejectsTitleOnlyWrongArtist() {
        let score = MusicController.scoreArtworkCandidate(
            title: "Invisible", artist: "mei ehara", album: "Ampersands",
            candidateTitle: "Invisible", candidateArtist: "Uiro", candidateAlbum: "iro iro Case.2"
        )
        XCTAssertFalse(score.isReliable, "Title-only fallback must not accept artwork from a different artist/album")
    }

    func testArtworkCandidateAcceptsLocalizedAlbumMatch() {
        let score = MusicController.scoreArtworkCandidate(
            title: "我的寶貝", artist: "Lee Chih Ching", album: "Yin Shi Nan Nu",
            candidateTitle: "我的宝贝", candidateArtist: "李之勤", candidateAlbum: "飲食男女"
        )
        XCTAssertTrue(score.isReliable)
        XCTAssertGreaterThanOrEqual(score.total, 5)
    }

    // ------------------------------------------------------------------
    // MARK: - Apple Music API recent history
    // ------------------------------------------------------------------

    func testParseRecentTracksResponseMapsSongAndLibrarySongResources() throws {
        let json = """
        {
          "data": [
            {
              "id": "123456789",
              "type": "songs",
              "attributes": {
                "name": "Song A",
                "artistName": "Artist A",
                "albumName": "Album A",
                "durationInMillis": 185000
              }
            },
            {
              "id": "i.abcdef",
              "type": "library-songs",
              "attributes": {
                "name": "Song B",
                "artistName": "Artist B",
                "albumName": "Album B",
                "durationInMillis": 201500
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let tracks = MusicController.parseRecentTracksResponse(json)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].title, "Song A")
        XCTAssertEqual(tracks[0].artist, "Artist A")
        XCTAssertEqual(tracks[0].album, "Album A")
        XCTAssertEqual(tracks[0].persistentID, "am:123456789")
        XCTAssertEqual(tracks[0].duration, 185)
        XCTAssertEqual(tracks[1].persistentID, "am:i.abcdef")
        XCTAssertEqual(tracks[1].duration, 201.5)
    }

    func testSameTrackIdentityDetectsQueueReorder() {
        let original = [
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.0),
            (title: "B", artist: "Artist", album: "Album", persistentID: "2", duration: 181.0),
        ]
        let reordered = [
            (title: "B", artist: "Artist", album: "Album", persistentID: "2", duration: 181.0),
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.0),
        ]

        XCTAssertFalse(MusicController.sameTrackIdentity(original, reordered))
    }

    func testSameTrackIdentityIgnoresTinyDurationDrift() {
        let original = [
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.0),
        ]
        let drifted = [
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.05),
        ]

        XCTAssertTrue(MusicController.sameTrackIdentity(original, drifted))
    }

    func testQueueSnapshotAppliesOnlyWhenQueueAndTrackGenerationsMatch() {
        XCTAssertTrue(MusicController.shouldApplyQueueSnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldApplyQueueSnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 4,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldApplyQueueSnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 8
        ))
    }

    func testPlaylistOpenCachedQueueRequiresCurrentGeneration() {
        XCTAssertTrue(MusicController.shouldUseCachedQueueForPlaylistOpen(
            hasVisibleQueueData: true,
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: true
        ))

        XCTAssertFalse(MusicController.shouldUseCachedQueueForPlaylistOpen(
            hasVisibleQueueData: true,
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: false
        ))
    }

    func testLyricWaveTimingKeepsOriginalTopDownWaveOrder() {
        let indices = Array(0...8)
        let schedule = LyricWaveTiming.staggerSchedule(for: indices, newIndex: 5)

        XCTAssertEqual(schedule.map(\.lineIndex), indices)
        XCTAssertEqual(Set(schedule.map(\.lineIndex)), Set(indices))
        XCTAssertEqual(schedule[0].delay, 0, accuracy: 0.0001)
        XCTAssertEqual(schedule[1].delay, 0, accuracy: 0.0001)
        XCTAssertEqual(schedule[2].delay, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(schedule[3].delay, 0)
        XCTAssertGreaterThan(schedule[5].delay, schedule[3].delay)
    }

    func testLyricWaveTimingStartsThreeRowsAboveActiveLineLikeOriginalAMLLWave() {
        let indices = Array(0...24)
        let schedule = LyricWaveTiming.staggerSchedule(for: indices, newIndex: 12)
        let activeDelay = schedule.first { $0.lineIndex == 12 }?.delay
        let zeroDelayRows = schedule.filter { $0.delay == 0 }.map(\.lineIndex)

        XCTAssertEqual(schedule.map(\.lineIndex), indices)
        XCTAssertEqual(zeroDelayRows, Array(0...9))
        XCTAssertEqual(activeDelay ?? 0, LyricWaveTiming.defaultBaseDelay * 3, accuracy: 0.001)
        XCTAssertEqual(Set(schedule.map(\.lineIndex)).count, indices.count)
    }

    func testLyricWaveTimingKeepsLeadInAtLineBoundaryWithoutPrewarm() {
        let indices = Array(0...24)
        let schedule = LyricWaveTiming.staggerSchedule(for: indices, newIndex: 12)
        let delays = Dictionary(uniqueKeysWithValues: schedule.map { ($0.lineIndex, $0.delay) })
        let activeDelay = delays[12] ?? 1

        XCTAssertEqual(schedule.map(\.lineIndex), indices)
        XCTAssertEqual(schedule.filter { $0.delay == 0 }.map(\.lineIndex), Array(0...9))
        XCTAssertGreaterThan(delays[10] ?? 0, 0)
        XCTAssertGreaterThan(delays[11] ?? 0, delays[10] ?? 1)
        XCTAssertGreaterThan(activeDelay, delays[11] ?? 1)
        XCTAssertEqual(activeDelay, LyricWaveTiming.defaultBaseDelay * 3, accuracy: 0.001)
        XCTAssertGreaterThan(delays[13] ?? 0, activeDelay)
    }

    func testLyricWaveTimingKeepsDensePlainLineLyricsOnTopDownDriftWave() {
        let indices = Array(0...18)
        let schedule = LyricWaveTiming.staggerSchedule(for: indices, newIndex: 6)
        let activeDelay = schedule.first { $0.lineIndex == 6 }?.delay
        let tailDelay = schedule.last?.delay

        XCTAssertEqual(schedule.map(\.lineIndex), indices)
        XCTAssertEqual(schedule.filter { $0.delay == 0 }.map(\.lineIndex), Array(0...3))
        XCTAssertEqual(activeDelay ?? 0, LyricWaveTiming.defaultBaseDelay * 3, accuracy: 0.001)
        XCTAssertGreaterThan(tailDelay ?? 0, activeDelay ?? 0)
    }

    func testLyricWaveTimingKeepsOriginalTargetWindow() {
        XCTAssertEqual(LyricWaveTiming.targetRadius(lineInterval: 0.9, hasSyllableSync: false), 14)
        XCTAssertEqual(LyricWaveTiming.targetRadius(lineInterval: 1.45, hasSyllableSync: false), 14)
        XCTAssertEqual(LyricWaveTiming.targetRadius(lineInterval: 1.6, hasSyllableSync: false), 14)
        XCTAssertEqual(LyricWaveTiming.targetRadius(lineInterval: 0.9, hasSyllableSync: true), 14)
        XCTAssertEqual(LyricWaveTiming.targetRadius(lineInterval: nil, hasSyllableSync: false), 14)
    }

    func testLyricWaveTimingCarriesExistingTargetsIntoNextWaveCleanup() {
        let indices = LyricWaveTiming.targetIndices(
            renderedIndices: Array(24...54),
            oldIndex: 64,
            newIndex: 30,
            radius: 6,
            existingTargetIndices: [37]
        )

        XCTAssertTrue(indices.contains(37))
        XCTAssertTrue(indices.contains(30))
        XCTAssertFalse(indices.contains(51))
    }

    func testLyricWaveTimingSeedsInterruptedNaturalAdvanceToCurrentOldLine() {
        let seeded = LyricWaveTiming.seededTargetsForNaturalAdvance(
            existingTargets: [
                10: 8,
                11: 8,
                40: 39
            ],
            indices: [10, 11, 12],
            oldIndex: 9
        )

        XCTAssertEqual(seeded[10], 9)
        XCTAssertEqual(seeded[11], 9)
        XCTAssertEqual(seeded[12], 9)
        XCTAssertEqual(seeded[40], 39)
    }

    func testLyricsPresentationEngineDirectSnapTargetsEveryRenderedRow() {
        let targets = LyricsPresentationEngine.directSnapTargets(
            renderedIndices: [1, 4, 7],
            targetIndex: 6
        )

        XCTAssertEqual(targets, [1: 6, 4: 6, 7: 6])
    }

    func testLyricsPresentationEngineNaturalPlanSeedsRowsToOldTargetBeforeWaveFires() {
        let plan = LyricsPresentationEngine.makeNaturalWavePlan(
            existingTargets: [40: 39],
            renderedIndices: Array(0...24),
            oldIndex: 8,
            newIndex: 12,
            lineInterval: 1.2,
            hasSyllableSync: true
        )

        XCTAssertEqual(plan.seededTargets[10], 8)
        XCTAssertEqual(plan.seededTargets[11], 8)
        XCTAssertEqual(plan.seededTargets[12], 8)
        XCTAssertEqual(plan.seededTargets[40], 39)
        XCTAssertEqual(plan.schedule.filter { $0.delay == 0 }.map(\.lineIndex), Array(0...9))
        XCTAssertEqual(
            plan.schedule.first { $0.lineIndex == 12 }?.delay ?? 0,
            LyricWaveTiming.defaultBaseDelay * 3,
            accuracy: 0.001
        )
    }

    func testNativeLyricsTimelinePolicyFindsLiveAndNextDisplayLine() {
        let rows = (0..<5).map { index in
            let line = LyricLine(
                text: "Line \(index)",
                startTime: Double(index) * 2.0,
                endTime: Double(index) * 2.0 + 1.5
            )
            let displayLine = DisplayLyricLine(
                id: "line-\(index)",
                sourceIndex: index,
                segmentIndex: 0,
                segmentCount: 1,
                line: line
            )
            return LayerBackedLyricRow(
                id: displayLine.id,
                index: index,
                displayLine: displayLine,
                sourceLine: line,
                isPrelude: index == 0,
                preludeEndTime: 0,
                interlude: nil
            )
        }

        XCTAssertEqual(
            NativeLyricsTimelinePolicy.liveDisplayIndex(at: 4.1, rows: rows, fallback: 0),
            2
        )
        XCTAssertEqual(
            NativeLyricsTimelinePolicy.nextLineStartTime(after: 4.1, rows: rows),
            6.0
        )
    }

    @MainActor
    func testLyricsPresentationEngineDirectSnapModeDoesNotUseNaturalWaveTargets() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 3,
                renderedIndices: Array(0...6),
                anchorY: 100,
                accumulatedHeights: Dictionary(uniqueKeysWithValues: (0...6).map { ($0, CGFloat($0 * 40)) }),
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .directSnap(.seek)
            ),
            onTargetsChanged: {}
        )

        XCTAssertTrue(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.targetIndex(for: 0, fallback: 3), 3)
        XCTAssertEqual(engine.targetIndex(for: 6, fallback: 3), 3)
        XCTAssertEqual(engine.presentation(for: 0)?.y, -20)
        XCTAssertEqual(engine.presentation(for: 6)?.y, 220)
    }

    @MainActor
    func testLyricsPresentationEngineNaturalModeOwnsSpringPresentation() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        let heights = Dictionary(uniqueKeysWithValues: (0...10).map { ($0, CGFloat($0 * 40)) })
        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 4,
                renderedIndices: Array(0...10),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: true,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .directSnap(.initialLayout)
            ),
            onTargetsChanged: {}
        )
        let oldY = engine.presentation(for: 4)?.y

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 5,
                renderedIndices: Array(0...10),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: true,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {}
        )

        XCTAssertEqual(engine.presentation(for: 5)?.targetIndex, 4)
        XCTAssertEqual(engine.presentation(for: 5)?.targetY, 140)
        XCTAssertEqual(engine.presentation(for: 5)?.y, 140)
        XCTAssertEqual(oldY, 100)
        XCTAssertEqual(engine.presentation(for: 0)?.targetIndex, 5)
        XCTAssertEqual(engine.presentation(for: 0)?.targetY, -100)
        XCTAssertEqual(engine.presentation(for: 0)?.y, -60)
        XCTAssertTrue(engine.hasActiveMotion)
        engine.advance(delta: 1.0 / 60.0)
        XCTAssertLessThan(engine.presentation(for: 0)?.y ?? 0, -60)
    }

    @MainActor
    func testLyricsPresentationEngineManualAndReducedMotionUseDirectPresentation() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        let heights = Dictionary(uniqueKeysWithValues: (0...6).map { ($0, CGFloat($0 * 40)) })

        for mode in [LyricsPresentationPlaybackMode.directSnap(.manualScroll), .directSnap(.reducedMotion)] {
            engine.update(
                LyricsPresentationEngineConfiguration(
                    currentIndex: 4,
                    renderedIndices: Array(0...6),
                    anchorY: 100,
                    accumulatedHeights: heights,
                    lineInterval: 1.2,
                    hasSyllableSync: false,
                    trackContext: track,
                    isWaveTimelineDiagnosticsEnabled: false,
                    playbackMode: mode
                ),
                onTargetsChanged: {}
            )

            XCTAssertTrue(engine.lineTargetIndices.isEmpty)
            XCTAssertEqual(engine.presentation(for: 2)?.targetIndex, 4)
            XCTAssertEqual(engine.presentation(for: 2)?.y, engine.presentation(for: 2)?.targetY)
            XCTAssertEqual(engine.presentation(for: 2)?.velocity, 0)
        }
    }

    @MainActor
    func testLyricsPresentationEngineDoesNotCarryDirectSnapTargetsIntoNativeCulling() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        let heights = Dictionary(uniqueKeysWithValues: (0...66).map { ($0, CGFloat($0 * 40)) })
        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 4,
                renderedIndices: Array(0...66),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: true,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .directSnap(.initialLayout)
            ),
            onTargetsChanged: {}
        )
        XCTAssertTrue(engine.lineTargetIndices.isEmpty)

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 5,
                renderedIndices: Array(0...66),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: true,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {}
        )

        XCTAssertLessThan(engine.lineTargetIndices.count, 40)
        XCTAssertFalse(Set(engine.lineTargetIndices.keys).isSuperset(of: Set(0...66)))
    }

    @MainActor
    func testLyricsPresentationEngineLargeNaturalJumpUsesDirectSnapRecovery() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        let heights = Dictionary(uniqueKeysWithValues: (0...30).map { ($0, CGFloat($0 * 40)) })
        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 4,
                renderedIndices: Array(0...30),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: true,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .directSnap(.initialLayout)
            ),
            onTargetsChanged: {}
        )

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 9,
                renderedIndices: Array(0...30),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: true,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {
                XCTFail("Large seek-style jumps must not schedule a natural wave.")
            }
        )

        XCTAssertTrue(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.presentation(for: 9)?.targetIndex, 9)
        XCTAssertEqual(engine.presentation(for: 9)?.y, engine.presentation(for: 9)?.targetY)
        XCTAssertEqual(engine.presentation(for: 14)?.targetIndex, 9)
        XCTAssertEqual(engine.presentation(for: 14)?.velocity, 0)
    }

    @MainActor
    func testLyricsPresentationEngineSnapsShortNaturalAdvanceSequenceAfterTapRecovery() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        let heights = Dictionary(uniqueKeysWithValues: (0...42).map { ($0, CGFloat($0 * 50)) })
        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 31,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .directSnap(.tapToLine)
            ),
            onTargetsChanged: {}
        )

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 32,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {
                XCTFail("First advance after tap recovery should snap, not start a stale wave.")
            }
        )

        XCTAssertTrue(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.presentation(for: 32)?.targetIndex, 32)
        XCTAssertEqual(engine.presentation(for: 32)?.y, engine.presentation(for: 32)?.targetY)

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 33,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {
                XCTFail("Second advance after tap recovery should still snap.")
            }
        )

        XCTAssertTrue(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.presentation(for: 33)?.targetIndex, 33)

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 34,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {
                XCTFail("Third advance after tap recovery should still snap.")
            }
        )

        XCTAssertTrue(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.presentation(for: 34)?.targetIndex, 34)

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 35,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {}
        )

        XCTAssertFalse(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.lineTargetIndices[35], 34)
    }

    @MainActor
    func testLyricsPresentationEngineDirectSnapsWhenNaturalBacklogFallsBehind() {
        let engine = LyricsPresentationEngine()
        let track = DiagnosticTrackContext(title: "Song", artist: "Artist", album: "Album", duration: 120)
        let heights = Dictionary(uniqueKeysWithValues: (0...42).map { ($0, CGFloat($0 * 50)) })
        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 31,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .directSnap(.initialLayout)
            ),
            onTargetsChanged: {}
        )

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 32,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {}
        )

        XCTAssertFalse(engine.lineTargetIndices.isEmpty)

        engine.update(
            LyricsPresentationEngineConfiguration(
                currentIndex: 33,
                renderedIndices: Array(0...42),
                anchorY: 100,
                accumulatedHeights: heights,
                lineInterval: 1.2,
                hasSyllableSync: false,
                trackContext: track,
                isWaveTimelineDiagnosticsEnabled: false,
                playbackMode: .natural
            ),
            onTargetsChanged: {
                XCTFail("Stale target backlog should snap instead of scheduling another wave.")
            }
        )

        XCTAssertTrue(engine.lineTargetIndices.isEmpty)
        XCTAssertEqual(engine.presentation(for: 33)?.targetIndex, 33)
        XCTAssertEqual(engine.presentation(for: 33)?.y, engine.presentation(for: 33)?.targetY)
    }

    func testLyricWaveAnimationSeedsCurrentLineBeforeNaturalAdvance() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lyricsView = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        let source = try String(contentsOf: lyricsView, encoding: .utf8)

        XCTAssertTrue(
            source.contains("seedWaveTargetsForLineAdvance(from: oldIndex, to: newIndex)"),
            "Natural lyric advances must seed the visible wave window before displayCurrentLineIndex changes so rows do not fall through to direct scroll."
        )
        XCTAssertTrue(
            source.contains("transaction.disablesAnimations = true"),
            "Seeding interrupted wave targets must not animate a catch-up-to-old-line correction before the protected wave starts."
        )
        XCTAssertTrue(
            source.contains("seededTargetsForNaturalAdvance"),
            "Rows inherited from an unfinished previous wave must be normalized to the current old line before the next protected wave starts."
        )
        XCTAssertFalse(
            source.contains("interruptedTargets"),
            "Interrupted lyric waves should not run a separate delayed rewind pass; seeding belongs directly at the natural line-advance boundary."
        )
        XCTAssertFalse(
            source.contains("recordLyricsWaveTimelineSamples(["),
            "Wave timeline diagnostics must be batched; recording diagnostics from every row fire path perturbs the animation timing being measured."
        )
    }

    func testNativeLyricsSurfaceOwnsWaveTimingOnFrameTick() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineURL = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsPresentationEngine.swift")
        let surfaceURL = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift")
        let modelURL = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift")
        let engine = try String(contentsOf: engineURL, encoding: .utf8)
        let surface = try String(contentsOf: surfaceURL, encoding: .utf8)
        let model = try String(contentsOf: modelURL, encoding: .utf8)

        XCTAssertTrue(
            model.contains("case native = \"native\""),
            "The rebuilt renderer must expose a native renderer mode instead of presenting the old layer path as the final architecture."
        )
        XCTAssertTrue(
            surface.contains("struct NativeLyricsSurface: NSViewRepresentable"),
            "SwiftUI should host the rebuilt renderer through NativeLyricsSurface."
        )
        XCTAssertTrue(
            engine.contains("advancePendingWave(delta:"),
            "AMLL-style wave retargeting must be advanced by the native frame loop."
        )
        XCTAssertFalse(
            engine.contains("DispatchWorkItem"),
            "Wave propagation must not rely on delayed main-queue work items; they drift under scroll/tap/jump load."
        )
        XCTAssertFalse(
            engine.contains("DispatchQueue.main.asyncAfter(deadline: .now() + scheduledDelay"),
            "Per-row wave timing belongs to the presentation tick, not asyncAfter timers."
        )
        XCTAssertTrue(
            surface.contains("lyrics.presentationFrame.summary"),
            "Native frame cadence telemetry is required to prove FPS/refresh has not been lowered."
        )
    }

    func testNativeRendererIsDefaultAfterUXGatesPass() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: LyricsRendererMode.userDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: LyricsRendererMode.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: LyricsRendererMode.userDefaultsKey)
            }
        }

        defaults.removeObject(forKey: LyricsRendererMode.userDefaultsKey)
        XCTAssertEqual(
            LyricsRendererMode.current,
            .native,
            "The native renderer is the default once manual scroll, hover, tap-to-jump, blur, FPS, drift, and CPU gates pass."
        )

        defaults.set("native", forKey: LyricsRendererMode.userDefaultsKey)
        XCTAssertEqual(LyricsRendererMode.current, .native)

        defaults.set("layer", forKey: LyricsRendererMode.userDefaultsKey)
        XCTAssertEqual(
            LyricsRendererMode.current,
            .native,
            "The old layer name is only a compatibility alias for the experimental native path."
        )
    }

    func testLyricsRendererModeResolutionUsesExplicitDomainsBeforeDeveloperFallback() {
        XCTAssertEqual(
            LyricsRendererMode.resolve(
                environmentRawValue: nil,
                standardRawValue: nil,
                developerRawValue: "native",
                isLocalDeveloperBuild: false
            ),
            LyricsRendererMode.Resolution(mode: .native, rawValue: nil, source: "default")
        )
        XCTAssertEqual(
            LyricsRendererMode.resolve(
                environmentRawValue: nil,
                standardRawValue: nil,
                developerRawValue: "native",
                isLocalDeveloperBuild: true
            ),
            LyricsRendererMode.Resolution(mode: .native, rawValue: "native", source: "developerContainerDefaults")
        )
        XCTAssertEqual(
            LyricsRendererMode.resolve(
                environmentRawValue: nil,
                standardRawValue: "swiftui",
                developerRawValue: "native",
                isLocalDeveloperBuild: true
            ),
            LyricsRendererMode.Resolution(mode: .swiftUI, rawValue: "swiftui", source: "userDefaults")
        )
        XCTAssertEqual(
            LyricsRendererMode.resolve(
                environmentRawValue: "engine",
                standardRawValue: "swiftui",
                developerRawValue: nil,
                isLocalDeveloperBuild: true
            ),
            LyricsRendererMode.Resolution(mode: .native, rawValue: "engine", source: "environment")
        )
    }

    func testWordLevelLyricsBypassDisplayChunking() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lyricsView = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        let source = try String(contentsOf: lyricsView, encoding: .utf8)
        guard let functionStart = source.range(of: "private func makeDisplayLyricLines")?.lowerBound,
              let functionEnd = source.range(of: "private func shouldKeepDisplayLineUnsplit")?.lowerBound else {
            XCTFail("Could not locate makeDisplayLyricLines in LyricsView.swift")
            return
        }
        let body = String(source[functionStart..<functionEnd])

        XCTAssertTrue(
            body.contains("if line.hasSyllableSync"),
            "Word-level lyrics must keep one source line as one display line."
        )
        XCTAssertFalse(
            body.contains("wordSegments"),
            "Display chunking must not split word-level lyrics into virtual rows; that changes sentence breaks and wave geometry."
        )
    }

    func testDeprecatedVisibleLyricMotionHudIsRemoved() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lyricsView = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        let source = try String(contentsOf: lyricsView, encoding: .utf8)

        XCTAssertFalse(
            source.contains("LyricsMotionDiagnosticsPanel"),
            "The visible lyric motion diagnostics panel is deprecated and must not ship in the app."
        )
        XCTAssertTrue(
            source.contains("recordLyricLineMotion"),
            "Removing the visible panel must not remove invisible line-motion capture."
        )
        XCTAssertTrue(
            source.contains("diagnosticLineMotionProbe"),
            "The hidden sampling probe is still required for motion verification."
        )
        XCTAssertTrue(
            source.contains("let appliedOffsetY = framesIncludeLineOffset\n                ? 0\n                : Double(fullOffset + effectiveManualOffset)"),
            "Native renderer frame telemetry already reports final visible row coordinates and must not double-count manual scroll offset."
        )
        XCTAssertTrue(
            source.contains(".offset(y: layerActive ? 0 : scroll.manualScrollOffset)"),
            "Native renderer mode must not keep the old SwiftUI manual-scroll offset wrapped around the native surface."
        )
        XCTAssertTrue(
            source.contains("isEnabled: currentPage == .lyrics && !lyricsLayerRendererActive"),
            "Native renderer mode must not keep the old global SwiftUI scroll detector active over the native surface."
        )
    }

    func testLyricLineAdvanceTimingReusesSameScheduledTarget() {
        XCTAssertTrue(LyricLineAdvanceTiming.shouldReuseScheduledTimer(
            existingTarget: 42.0,
            nextTarget: 42.008,
            timerActive: true
        ))
        XCTAssertFalse(LyricLineAdvanceTiming.shouldReuseScheduledTimer(
            existingTarget: 42.0,
            nextTarget: 42.08,
            timerActive: true
        ))
        XCTAssertFalse(LyricLineAdvanceTiming.shouldReuseScheduledTimer(
            existingTarget: 42.0,
            nextTarget: 42.0,
            timerActive: false
        ))
    }

    func testNativeLyricsPageDefersBackgroundLyricsPreload() {
        XCTAssertFalse(NearbyAssetPreloadPolicy.shouldPreloadLyrics(
            currentPage: .lyrics,
            rendererMode: .native
        ))
        XCTAssertTrue(NearbyAssetPreloadPolicy.shouldPreloadLyrics(
            currentPage: .lyrics,
            rendererMode: .swiftUI
        ))
        XCTAssertTrue(NearbyAssetPreloadPolicy.shouldPreloadLyrics(
            currentPage: .album,
            rendererMode: .native
        ))
        XCTAssertTrue(NearbyAssetPreloadPolicy.shouldPreloadLyrics(
            currentPage: .playlist,
            rendererMode: .native
        ))
    }

    func testNativeLayerRowsAreCachedOutsideSwiftUIBody() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lyricsView = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        let source = try String(contentsOf: lyricsView, encoding: .utf8)
        guard let bodyStart = source.range(of: "private var scrollableLyricsContent")?.lowerBound,
              let bodyEnd = source.range(of: "// MARK: - Lyric Line Helpers")?.lowerBound,
              let refreshStart = source.range(of: "private func refreshDisplayLineCache")?.lowerBound,
              let refreshEnd = source.range(of: "private func displayIndex(forSourceIndex sourceIndex: Int)")?.lowerBound else {
            XCTFail("Could not locate native lyrics row cache sections")
            return
        }

        let body = String(source[bodyStart..<bodyEnd])
        let refreshBody = String(source[refreshStart..<refreshEnd])

        XCTAssertTrue(
            source.contains("@State private var cachedLayerRows"),
            "Native row models should be semantic cached state, not rebuilt by SwiftUI shell invalidations."
        )
        XCTAssertFalse(
            body.contains("makeLayerBackedRows(from:"),
            "The SwiftUI body must not rebuild native row models on progress, hover, or layout ticks."
        )
        XCTAssertTrue(
            refreshBody.contains("makeLayerBackedRows(from: displayLines)"),
            "Native row models should be rebuilt when the display lyrics payload changes."
        )
    }

    func testPlaybackPositionCorrectionDefersLargeBackwardResetWhileLyricsAreVisible() {
        XCTAssertTrue(
            PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
                polledPosition: 3.65,
                interpolatedPosition: 27.66,
                duration: 210,
                isPlaying: true,
                seekPending: false,
                consecutiveDeferrals: 0
            )
        )
    }

    func testPlaybackPositionCorrectionEventuallyAcceptsUnverifiableRepeatedReset() {
        XCTAssertFalse(
            PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
                polledPosition: 0.92,
                interpolatedPosition: 28.66,
                duration: 210,
                isPlaying: true,
                seekPending: false,
                consecutiveDeferrals: PlaybackPositionCorrectionPolicy.maxConsecutiveTransientResetDeferrals
            )
        )
    }

    func testPlaybackPositionCorrectionDoesNotBlockUserSeekOrTrackLoop() {
        XCTAssertFalse(
            PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
                polledPosition: 0.8,
                interpolatedPosition: 34,
                duration: 210,
                isPlaying: true,
                seekPending: true
            )
        )
        XCTAssertFalse(
            PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
                polledPosition: 0.8,
                interpolatedPosition: 207,
                duration: 210,
                isPlaying: true,
                seekPending: false
            )
        )
    }

    func testPlaybackPositionCorrectionAllowsNormalSmallDriftCorrection() {
        XCTAssertFalse(
            PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
                polledPosition: 42.0,
                interpolatedPosition: 45.0,
                duration: 210,
                isPlaying: true,
                seekPending: false
            )
        )
    }

    func testVisibleLyricClockCorrectionUsesSameThresholdAsWordHighlight() {
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldCorrectVisibleLyrics(
            drift: 0.12,
            isLyricsVisible: true,
            isManualScrolling: false
        ))
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldCorrectVisibleLyrics(
            drift: -0.12,
            isLyricsVisible: true,
            isManualScrolling: false
        ))
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldCorrectVisibleLyrics(
            drift: 0.09,
            isLyricsVisible: true,
            isManualScrolling: false
        ))
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldCorrectVisibleLyrics(
            drift: 0.20,
            isLyricsVisible: false,
            isManualScrolling: false
        ))
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldCorrectVisibleLyrics(
            drift: 0.20,
            isLyricsVisible: true,
            isManualScrolling: true
        ))
    }

    func testLyricMotionSamplingUsesPlaybackDerivedActiveIndex() {
        let lyrics = [
            LyricLine(text: "...", startTime: 0, endTime: 10),
            LyricLine(text: "first", startTime: 10, endTime: 14),
            LyricLine(text: "second", startTime: 14, endTime: 18),
            LyricLine(text: "third", startTime: 21, endTime: 25)
        ]

        XCTAssertEqual(
            LyricMotionSamplingPolicy.activeIndex(at: 9.5, lyrics: lyrics, firstRealIndex: 1),
            0
        )
        XCTAssertEqual(
            LyricMotionSamplingPolicy.activeIndex(at: 15.0, lyrics: lyrics, firstRealIndex: 1),
            2
        )
    }

    func testLyricMotionSamplingElevatesNearLineBoundaryOnly() {
        let lyrics = [
            LyricLine(text: "...", startTime: 0, endTime: 10),
            LyricLine(text: "first", startTime: 10, endTime: 14),
            LyricLine(text: "second", startTime: 14, endTime: 18)
        ]

        XCTAssertEqual(
            LyricMotionSamplingPolicy.sampleInterval(
                focusedWindowActive: false,
                playbackTime: 9.95,
                lyrics: lyrics,
                firstRealIndex: 1
            ),
            LyricMotionSamplingPolicy.boundaryInterval,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricMotionSamplingPolicy.sampleInterval(
                focusedWindowActive: false,
                playbackTime: 12.0,
                lyrics: lyrics,
                firstRealIndex: 1
            ),
            LyricMotionSamplingPolicy.idleInterval,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricMotionSamplingPolicy.sampleInterval(
                focusedWindowActive: true,
                playbackTime: 12.0,
                lyrics: lyrics,
                firstRealIndex: 1
            ),
            LyricMotionSamplingPolicy.focusedInterval,
            accuracy: 0.0001
        )
    }

    func testLyricMotionBoundarySamplingIsPreciseEnoughForSettleGate() {
        XCTAssertLessThanOrEqual(
            LyricMotionSamplingPolicy.boundaryInterval,
            LyricMotionSamplingPolicy.focusedInterval
        )
        XCTAssertLessThan(
            LyricMotionSamplingPolicy.boundaryInterval * 2,
            0.45
        )
    }
}
