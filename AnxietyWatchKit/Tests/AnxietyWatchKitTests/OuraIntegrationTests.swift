import XCTest
@testable import AnxietyWatchKit

final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    var mockData: Data?
    var mockResponse: URLResponse?
    var mockError: Error?
    /// The most recent request passed to `data(for:)`, for asserting on
    /// outgoing URL / headers / body (e.g. postTokenToServer).
    private(set) var lastRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        if let error = mockError { throw error }
        return (mockData ?? Data(), mockResponse ?? URLResponse())
    }
}

final class OuraIntegrationTests: XCTestCase {

    func testIBIParsing() async throws {
        let json = """
        {
            "data": [
                {
                    "id": "abc",
                    "timestamp": "2023-11-20T21:00:00+00:00",
                    "timestamp_unix": 1700514000,
                    "ibi": 850,
                    "validity": 1
                }
            ],
            "next_token": null
        }
        """

        let mockSession = MockURLSession()
        mockSession.mockData = json.data(using: .utf8)
        let response = HTTPURLResponse(url: URL(string: "https://api.ouraring.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
        mockSession.mockResponse = response

        let client = OuraAPIClient(session: mockSession)
        await client.setAccessToken("test_token")

        let ibiData = try await client.fetchIBI(startDate: "2023-11-20", endDate: "2023-11-21")
        XCTAssertEqual(ibiData.count, 1)
        XCTAssertEqual(ibiData[0].ibi, 850)
        XCTAssertEqual(ibiData[0].validity, .good)
    }

    func testRateLimitError() async throws {
        let mockSession = MockURLSession()
        mockSession.mockData = Data()
        let response = HTTPURLResponse(url: URL(string: "https://api.ouraring.com")!, statusCode: 429, httpVersion: nil, headerFields: ["X-RateLimit-Tier": "per_app"])
        mockSession.mockResponse = response

        let client = OuraAPIClient(session: mockSession)
        await client.setAccessToken("test_token")

        do {
            _ = try await client.fetchSleep(startDate: "2023-11-20", endDate: "2023-11-21")
            XCTFail("Should throw rate limited")
        } catch OuraAPIError.rateLimited(let tier) {
            XCTAssertEqual(tier, "per_app")
        } catch {
            XCTFail("Wrong error")
        }
    }

    func testPostTokenToServerBuildsAuthedRequest() async throws {
        let mockSession = MockURLSession()
        mockSession.mockResponse = HTTPURLResponse(
            url: URL(string: "https://sync.example.com/api/oura/auth")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )
        let client = OuraAPIClient(session: mockSession)
        let token = OuraTokenStore.Token(
            accessToken: "acc", refreshToken: "ref",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000), tokenType: "Bearer"
        )

        try await client.postTokenToServer(baseURL: "https://sync.example.com", apiKey: "KEY123", token: token)

        let req = try XCTUnwrap(mockSession.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://sync.example.com/api/oura/auth")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer KEY123")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["access_token"] as? String, "acc")
        XCTAssertEqual(json["refresh_token"] as? String, "ref")
        XCTAssertNotNil(json["expires_at"] as? String)  // ISO8601 string
    }

    func testPostTokenToServerThrowsOnNon2xx() async {
        let mockSession = MockURLSession()
        mockSession.mockResponse = HTTPURLResponse(
            url: URL(string: "https://sync.example.com/api/oura/auth")!,
            statusCode: 500, httpVersion: nil, headerFields: nil
        )
        let client = OuraAPIClient(session: mockSession)
        let token = OuraTokenStore.Token(
            accessToken: "acc", refreshToken: "ref", expiresAt: Date(), tokenType: "Bearer"
        )
        do {
            try await client.postTokenToServer(baseURL: "https://sync.example.com", apiKey: "KEY", token: token)
            XCTFail("Expected an error for a non-2xx response")
        } catch {
            // expected — server rejected the token post
        }
    }
}
