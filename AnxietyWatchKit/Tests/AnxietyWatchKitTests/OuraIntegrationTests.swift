import XCTest
@testable import AnxietyWatchKit

final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    var mockData: Data?
    var mockResponse: URLResponse?
    var mockError: Error?
    
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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
}
