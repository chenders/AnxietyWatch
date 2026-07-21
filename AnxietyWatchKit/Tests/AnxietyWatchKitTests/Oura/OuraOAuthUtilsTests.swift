import Testing
import Foundation
@testable import AnxietyWatchKit

@Suite("Oura OAuth Utils Tests")
struct OuraOAuthUtilsTests {
    @Test("authorizeURL constructs correct URL")
    func testAuthorizeURL() {
        let url = OuraOAuthUtils.authorizeURL(
            clientID: "test_client",
            redirectURI: "app://callback",
            scopes: ["email", "personal"],
            state: "test_state"
        )
        
        #expect(url?.scheme == "https")
        #expect(url?.host == "cloud.ouraring.com")
        #expect(url?.path == "/oauth/authorize")
        
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let queryItems = components.queryItems!
        
        #expect(queryItems.contains { $0.name == "client_id" && $0.value == "test_client" })
        #expect(queryItems.contains { $0.name == "redirect_uri" && $0.value == "app://callback" })
        #expect(queryItems.contains { $0.name == "response_type" && $0.value == "code" })
        #expect(queryItems.contains { $0.name == "scope" && $0.value == "email personal" })
        #expect(queryItems.contains { $0.name == "state" && $0.value == "test_state" })
    }

    @Test("decodeTokenResponse decodes and calculates expiresAt")
    func testDecodeTokenResponse() throws {
        let json = """
        {
            "access_token": "acc_123",
            "refresh_token": "ref_456",
            "expires_in": 3600,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!
        
        let now = Date(timeIntervalSince1970: 100000)
        let token = try OuraOAuthUtils.decodeTokenResponse(data: json, date: now)
        
        #expect(token.accessToken == "acc_123")
        #expect(token.refreshToken == "ref_456")
        #expect(token.tokenType == "Bearer")
        #expect(token.expiresAt.timeIntervalSince1970 == 103600)
    }
}
