/**
 * [INPUT]: MusicMiniPlayerCore RowArtworkStore
 * [OUTPUT]: Unit tests for the playlist-row artwork tier store
 * [POS]: Test module. Pins the 2026-07-17 defect chain: row-fetched artwork was
 *        never cached (every row recreation refetched the network), duplicate
 *        concurrent fetches hit the same key in the same second ('Round
 *        Midnight ×2), and web-sourced art vanished on memory eviction because
 *        it never reached disk. The store must serve memory → disk (Apple tier,
 *        then web tier) → single-flighted network, and persist by source tier.
 */

import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class RowArtworkStoreTests: XCTestCase {

    private static let key: NSString = "meta:test title|test artist|test album"

    private final class Harness {
        var memory: [NSString: NSImage] = [:]
        var disk: [NSString: NSImage] = [:]
        var fetchCount = 0
        var fetchResult: (image: NSImage, appleAuthoritative: Bool)?
        var fetchDelayNanoseconds: UInt64 = 0

        @MainActor func makeStore() -> RowArtworkStore {
            RowArtworkStore(
                memoryRead: { self.memory[$0] },
                memoryWrite: { image, key in self.memory[key] = image },
                diskRead: { self.disk[$0] },
                diskWrite: { image, key in self.disk[key] = image },
                fetch: { _, _, _ in
                    self.fetchCount += 1
                    if self.fetchDelayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: self.fetchDelayNanoseconds)
                    }
                    return self.fetchResult
                }
            )
        }
    }

    private func makeImage() -> NSImage { NSImage(size: NSSize(width: 4, height: 4)) }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Cache tiers short-circuit the network
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_memoryHit_neverFetches() async {
        let harness = Harness()
        let image = makeImage()
        harness.memory[Self.key] = image
        let store = harness.makeStore()

        let result = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)

        XCTAssertTrue(result === image)
        XCTAssertEqual(harness.fetchCount, 0)
    }

    func test_appleTierDiskHit_promotesToMemory_neverFetches() async {
        let harness = Harness()
        let image = makeImage()
        harness.disk[Self.key] = image
        let store = harness.makeStore()

        let result = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)

        XCTAssertTrue(result === image)
        XCTAssertTrue(harness.memory[Self.key] === image)
        XCTAssertEqual(harness.fetchCount, 0)
    }

    func test_webTierDiskHit_servesWhenAppleTierAbsent() async {
        let harness = Harness()
        let image = makeImage()
        harness.disk[RowArtworkStore.webTierKey(Self.key)] = image
        let store = harness.makeStore()

        let result = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)

        XCTAssertTrue(result === image)
        XCTAssertEqual(harness.fetchCount, 0)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fetch results persist by source tier
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_appleFetch_persistsUnderAppleTierKey() async {
        let harness = Harness()
        let image = makeImage()
        harness.fetchResult = (image, appleAuthoritative: true)
        let store = harness.makeStore()

        let result = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)

        XCTAssertTrue(result === image)
        XCTAssertTrue(harness.memory[Self.key] === image)
        XCTAssertTrue(harness.disk[Self.key] === image)
        XCTAssertNil(harness.disk[RowArtworkStore.webTierKey(Self.key)])
    }

    func test_webFetch_persistsUnderWebTierKey() async {
        let harness = Harness()
        let image = makeImage()
        harness.fetchResult = (image, appleAuthoritative: false)
        let store = harness.makeStore()

        let result = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)

        XCTAssertTrue(result === image)
        XCTAssertTrue(harness.memory[Self.key] === image)
        XCTAssertTrue(harness.disk[RowArtworkStore.webTierKey(Self.key)] === image)
        XCTAssertNil(harness.disk[Self.key])
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Single-flight merge and failure behavior
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_concurrentRequests_executeOneFetch() async {
        let harness = Harness()
        let image = makeImage()
        harness.fetchResult = (image, appleAuthoritative: true)
        harness.fetchDelayNanoseconds = 50_000_000
        let store = harness.makeStore()

        async let first = store.artwork(title: "t", artist: "a", album: "al", key: Self.key)
        async let second = store.artwork(title: "t", artist: "a", album: "al", key: Self.key)
        let results = await [first, second]

        XCTAssertTrue(results[0] === image)
        XCTAssertTrue(results[1] === image)
        XCTAssertEqual(harness.fetchCount, 1)
    }

    func test_failedFetch_cachesNothing_andNextCallRetries() async {
        let harness = Harness()
        harness.fetchResult = nil
        let store = harness.makeStore()

        let miss = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)
        XCTAssertNil(miss)
        XCTAssertTrue(harness.memory.isEmpty)
        XCTAssertTrue(harness.disk.isEmpty)

        let image = makeImage()
        harness.fetchResult = (image, appleAuthoritative: true)
        let recovered = await store.artwork(title: "t", artist: "a", album: "al", key: Self.key)

        XCTAssertTrue(recovered === image)
        XCTAssertEqual(harness.fetchCount, 2)
    }
}
