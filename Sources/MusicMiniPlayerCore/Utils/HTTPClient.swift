/**
 * [INPUT]: Foundation URLSession
 * [OUTPUT]: HTTPClient 统一 HTTP 请求工具 + NetworkOutcomeLedger (protocol vs transport evidence)
 * [POS]: Utils 的网络子模块，替代分散的 URLRequest 模式
 * [PROTOCOL]: 变更时更新此头部，然后检查 Utils/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - Network Outcome Ledger
// ============================================================

/// Counts, per fetch pipeline, how many HTTP requests produced a PROTOCOL
/// RESPONSE (the server answered with any status — even 404/500 proves the
/// internet works) versus how many died as TRANSPORT FAILURES (timeout, DNS,
/// cannot-connect, offline — no server ever answered).
///
/// Why: "no source had lyrics" and "no request ever reached a server" look
/// identical at the call sites (both end as empty results), but they demand
/// opposite verdicts — the first may be cached for 24h as "no lyrics exist",
/// the second must surface as "network unreachable" and never be cached.
///
/// Binding model: a `@TaskLocal`. Each fetch pipeline binds its own fresh
/// ledger so concurrent pipelines (foreground fetch vs backfill vs preload)
/// cannot mix evidence. DEFAULT-ALLOW: when no ledger is bound (`current ==
/// nil`) nothing records and nothing gates — the LyricsVerifier CLI and any
/// other unbound caller behave exactly as before this ledger existed.
public final class NetworkOutcomeLedger: @unchecked Sendable {

    /// Task-local binding. `nil` (the default) means "no ledger": recording
    /// becomes a no-op and persistence gates stay open (default-allow).
    @TaskLocal public static var current: NetworkOutcomeLedger?

    /// Classification of a single request outcome.
    public enum RequestOutcome: Equatable {
        /// The server answered at the HTTP layer (any status code).
        case protocolResponse
        /// The request died in transport — no server ever answered.
        case transportFailure
        /// The task was cancelled — says nothing about the network, so it
        /// must be excluded from BOTH counters (the time-budget loop cancels
        /// stragglers on every normal fetch; counting those as failures
        /// would block every legitimate negative-verdict write).
        case cancelled
        /// Anything else (bad URL, undecodable body, …) — no evidence
        /// either way, excluded from both counters.
        case indeterminate
    }

    // NSLock over the two counters: recordings arrive from URLSession
    // completion contexts on arbitrary threads inside one task group.
    private let lock = NSLock()
    private var protocolResponseCount = 0
    private var transportFailureCount = 0

    public init() {}

    public var protocolResponses: Int {
        lock.withLock { protocolResponseCount }
    }

    public var transportFailures: Int {
        lock.withLock { transportFailureCount }
    }

    /// Quorum check for negative verdicts: a "no lyrics exist" cache write
    /// is only trustworthy when every counted request got a real answer.
    public var hadTransportFailures: Bool {
        transportFailures > 0
    }

    /// The honest offline verdict: nobody answered AND someone died trying.
    /// Zero traffic on both counters is NOT unreachable — it means the
    /// pipeline was answered from caches and never needed the network.
    public var indicatesNetworkUnreachable: Bool {
        lock.withLock { protocolResponseCount == 0 && transportFailureCount > 0 }
    }

    func recordProtocolResponse() {
        lock.withLock { protocolResponseCount += 1 }
    }

    /// Record a thrown request error according to the classification table.
    func record(failure error: Error) {
        guard Self.classify(failure: error) == .transportFailure else { return }
        lock.withLock { transportFailureCount += 1 }
    }

    /// The classification table for thrown request errors. Pure function so
    /// unit tests can pin every row. Conservative by design: only errors
    /// that PROVE the transport layer failed count as transport failures —
    /// an unknown error must never be able to flip the verdict to
    /// "network unreachable".
    public static func classify(failure error: Error) -> RequestOutcome {
        // Swift-concurrency cancellation (Task.checkCancellation paths).
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .indeterminate }

        switch urlError.code {
        // URLSession surfaces task cancellation as URLError(.cancelled).
        case .cancelled:
            return .cancelled

        // The request never produced an HTTP answer: dead in transport.
        case .timedOut,
             .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .dataNotAllowed,
             // TLS/certificate family: TCP may have connected but no HTTP
             // exchange happened — this is also the captive-portal signature,
             // which for lyrics purposes IS "network unreachable".
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .transportFailure

        // Everything else (.badURL, .badServerResponse, .cannotParseResponse,
        // .httpTooManyRedirects, …) either implies the server DID answer or
        // is a local programming error — no transport evidence.
        default:
            return .indeterminate
        }
    }
}

// ============================================================
// MARK: - HTTP 客户端
// ============================================================

/// 统一 HTTP 请求工具 - 封装常用配置和错误处理
public enum HTTPClient {

    // ── 配置 ──

    private static let defaultUserAgent = "nanoPod/1.0"
    public static let defaultTimeout: TimeInterval = 6.0

    private static let retryableStatusCodes: Set<Int> = [429, 502, 503, 504]

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // ── 错误类型 ──

    public enum HTTPError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int)
        case notFound
        case noData
        case decodingFailed

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response"
            case .httpError(let code): return "HTTP error: \(code)"
            case .notFound: return "Not found (404)"
            case .noData: return "No data"
            case .decodingFailed: return "Decoding failed"
            }
        }
    }

    // ── 公共接口 ──

    /// GET 请求并解码 JSON
    public static func get<T: Decodable>(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> T {
        let (data, _) = try await getData(url: url, headers: headers, timeout: timeout)

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decodingFailed
        }
    }

    /// GET 请求返回原始数据
    public static func getData(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout,
        retry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await _performGet(url: url, headers: headers, timeout: timeout)
        } catch {
            guard retry, !Task.isCancelled else { throw error }
            let shouldRetry: Bool
            if let httpErr = error as? HTTPError, case .httpError(let code) = httpErr {
                shouldRetry = retryableStatusCodes.contains(code)
            } else if (error as? URLError)?.code == .timedOut {
                shouldRetry = true
            } else {
                shouldRetry = false
            }
            guard shouldRetry else { throw error }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { throw error }
            return try await _performGet(url: url, headers: headers, timeout: timeout)
        }
    }

    private static func _performGet(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if headers["User-Agent"] == nil {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        // Ledger choke point: classify the raw session call only. Status
        // errors thrown BELOW (404/5xx) already proved the server answered,
        // so the protocol response is recorded before they are raised.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sharedSession.data(for: request)
        } catch {
            NetworkOutcomeLedger.current?.record(failure: error)
            throw error
        }
        // Any URLResponse object means the transport delivered an answer.
        NetworkOutcomeLedger.current?.recordProtocolResponse()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            throw HTTPError.notFound
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw HTTPError.httpError(statusCode: httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    /// GET 请求返回字符串
    public static func getString(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout,
        retry: Bool = true
    ) async throws -> String {
        let (data, _) = try await getData(url: url, headers: headers, timeout: timeout, retry: retry)

        guard let string = String(data: data, encoding: .utf8) else {
            throw HTTPError.decodingFailed
        }

        return string
    }

    /// GET 请求返回 JSON 字典
    public static func getJSON(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout,
        retry: Bool = true
    ) async throws -> [String: Any] {
        let (data, _) = try await getData(url: url, headers: headers, timeout: timeout, retry: retry)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.decodingFailed
        }

        return json
    }

    /// POST JSON 请求返回 JSON 字典
    public static func postJSON(
        url: URL,
        body: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if headers["User-Agent"] == nil {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Same ledger choke point as _performGet — QQ Music search rides on
        // POST, so transport evidence must be collected here too.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sharedSession.data(for: request)
        } catch {
            NetworkOutcomeLedger.current?.record(failure: error)
            throw error
        }
        NetworkOutcomeLedger.current?.recordProtocolResponse()

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HTTPError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.decodingFailed
        }

        return json
    }

    // ── 便捷方法 ──

    /// Pre-warm TLS connections to critical lyrics hosts.
    public static func warmup() {
        let hosts = [
            "https://music.163.com",
            "https://lrclib.net",
            "https://u.y.qq.com",
            "https://cdn.jsdelivr.net"
        ]
        for urlString in hosts {
            guard let url = URL(string: urlString) else { continue }
            Task {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 3.0
                _ = try? await sharedSession.data(for: request)
            }
        }
    }

    /// 构建带查询参数的 URL
    public static func buildURL(
        base: String,
        queryItems: [String: String]
    ) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }
}
