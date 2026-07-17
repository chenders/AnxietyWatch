import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Concrete `SyncEndpoint` wrapping HTTP POST to the sync server (§2.7).
///
/// The server URL is injected so a local/dev instance can be used during
/// development, and the production URL in release builds.
public struct RESTClient: SyncEndpoint, Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func pull(cursor: TableCursors, maxBatchBytes: Int) async throws -> SyncPullResponse {
        var req = try buildRequest(path: "/sync/pull")
        req.httpBody = try encoder.encode(PullRequest(cursor: cursor, maxBatchBytes: maxBatchBytes))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(req, as: SyncPullResponse.self)
    }

    public func push(payload: SyncPushPayload) async throws -> SyncPushResponse {
        var req = try buildRequest(path: "/sync/push")
        req.httpBody = try encoder.encode(payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(req, as: SyncPushResponse.self)
    }

    // MARK: - Private

    private func buildRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SyncEndpointError.permanent("Invalid URL: \(baseURL)\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        return req
    }

    private func perform<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncEndpointError.permanent("Not an HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 409:
            throw SyncEndpointError.cursorFormatMismatch
        case 408, 429, 502, 503, 504:
            throw SyncEndpointError.transientFailure("HTTP \(http.statusCode)")
        default:
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SyncEndpointError.permanent("HTTP \(http.statusCode): \(body)")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SyncEndpointError.permanent("JSON decode failed: \(error)")
        }
    }
}

// MARK: - Request/response wrappers

private struct PullRequest: Codable {
    let cursor: TableCursors
    let maxBatchBytes: Int

    enum CodingKeys: String, CodingKey {
        case cursor
        case maxBatchBytes = "max_batch_bytes"
    }
}
