/**
 * [INPUT]: Foundation URLSession
 * [OUTPUT]: HTTPClient 统一 HTTP 请求工具
 * [POS]: Utils 的网络子模块，替代分散的 URLRequest 模式
 * [PROTOCOL]: 变更时更新此头部，然后检查 Utils/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - HTTP 客户端
// ============================================================

/// 统一 HTTP 请求工具 - 封装常用配置和错误处理
public enum HTTPClient {

    // ── 配置 ──

    private static let defaultUserAgent = "nanoPod/1.0"
    public static let defaultTimeout: TimeInterval = 6.0

    // 🔑 共享 ephemeral session：复用 TLS 连接和 DNS 缓存，避免每次请求重建
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 30
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
        timeout: TimeInterval = defaultTimeout
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData  // 🔑 禁用缓存

        // 应用自定义 headers（覆盖默认 User-Agent）
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 如果没有自定义 User-Agent，使用默认值
        if headers["User-Agent"] == nil {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        let (data, response) = try await sharedSession.data(for: request)

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
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let (data, _) = try await getData(url: url, headers: headers, timeout: timeout)

        guard let string = String(data: data, encoding: .utf8) else {
            throw HTTPError.decodingFailed
        }

        return string
    }

    /// GET 请求返回 JSON 字典
    public static func getJSON(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [String: Any] {
        let (data, _) = try await getData(url: url, headers: headers, timeout: timeout)

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

        let (data, response) = try await sharedSession.data(for: request)

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
