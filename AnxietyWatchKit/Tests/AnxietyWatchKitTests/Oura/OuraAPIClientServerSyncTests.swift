import Testing
import Foundation
@testable import AnxietyWatchKit

/// Swift Testing coverage for OuraAPIClient.postTokenToServer (the sync-server
/// hand-off). Uses the shared MockURLSession from OuraIntegrationTests.swift
/// (same test target), which captures the outgoing request for assertions.
@Suite("Oura server-sync (postTokenToServer)")
struct OuraAPIClientServerSyncTests {
    @Test("builds an authed POST to /api/oura/auth with the token body")
    func buildsAuthedRequest() async throws {
        let mockSession = MockURLSession()
        mockSession.mockResponse = HTTPURLResponse(
            url: try #require(URL(string: "https://sync.example.com/api/oura/auth")),
            statusCode: 200, httpVersion: nil, headerFields: nil
        )
        let client = OuraAPIClient(session: mockSession)
        let token = OuraTokenStore.Token(
            accessToken: "acc", refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000), tokenType: "Bearer"
        )

        try await client.postTokenToServer(baseURL: "https://sync.example.com", apiKey: "KEY123", token: token)

        let req = try #require(mockSession.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://sync.example.com/api/oura/auth")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer KEY123")
        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["access_token"] as? String == "acc")
        #expect(json["refresh_token"] as? String == "ref")
        #expect(json["expires_at"] is String)  // ISO8601 string
    }

    @Test("throws on a non-2xx response")
    func throwsOnNon2xx() async throws {
        let mockSession = MockURLSession()
        mockSession.mockResponse = HTTPURLResponse(
            url: try #require(URL(string: "https://sync.example.com/api/oura/auth")),
            statusCode: 500, httpVersion: nil, headerFields: nil
        )
        let client = OuraAPIClient(session: mockSession)
        let token = OuraTokenStore.Token(
            accessToken: "acc", refreshToken: "ref", expiresAt: Date(), tokenType: "Bearer"
        )
        await #expect(throws: (any Error).self) {
            try await client.postTokenToServer(baseURL: "https://sync.example.com", apiKey: "KEY", token: token)
        }
    }
}
