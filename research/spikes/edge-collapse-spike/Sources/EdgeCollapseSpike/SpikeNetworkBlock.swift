/**
 * [INPUT]: ECS_ALLOW_NETWORK environment variable (unset = block).
 * [OUTPUT]: SpikeNetworkBlock.install() — every http(s) request the spike
 *           makes fails immediately as "not connected to the internet".
 * [POS]: Spike-only. The spike hosts the real MusicController / lyrics
 *        pipeline, which would query iTunes and lyrics sources; the prototype
 *        only needs Music.app's own artwork and playback state. 2026-09-22:
 *        the machine's IP was rate-limited by itunes.apple.com and another
 *        session needed the quota for artwork measurements.
 * [PROTOCOL]: Must run before anything touches HTTPClient (its session is a
 *             lazily-built static from URLSessionConfiguration.ephemeral).
 *             Covers URLSession.shared via registerClass and every
 *             default/ephemeral configuration via protocolClasses.
 */

import Foundation
import ObjectiveC

final class SpikeBlockingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var blocked = 0

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.blocked += 1
        if Self.blocked <= 20 { print("[EdgeCollapse] network blocked \(request.url?.host ?? "?")") }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

enum SpikeNetworkBlock {
    static func install() {
        guard ProcessInfo.processInfo.environment["ECS_ALLOW_NETWORK"] == nil else {
            print("[EdgeCollapse] network allowed (ECS_ALLOW_NETWORK)")
            return
        }
        URLProtocol.registerClass(SpikeBlockingURLProtocol.self)
        swizzleConfiguration(#selector(getter: URLSessionConfiguration.ephemeral))
        swizzleConfiguration(#selector(getter: URLSessionConfiguration.default))
        print("[EdgeCollapse] network blocked for this spike (set ECS_ALLOW_NETWORK=1 to allow)")
    }

    /// Replace the class getter with one that prepends the blocking protocol.
    private static func swizzleConfiguration(_ selector: Selector) {
        let cls: AnyClass = object_getClass(URLSessionConfiguration.self)!
        guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else { return }
        typealias Getter = @convention(c) (AnyClass, Selector) -> URLSessionConfiguration
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyClass) -> URLSessionConfiguration = { receiver in
            let config = original(receiver, selector)
            config.protocolClasses = [SpikeBlockingURLProtocol.self] + (config.protocolClasses ?? [])
            return config
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
}
