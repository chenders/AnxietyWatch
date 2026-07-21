import Testing
import Foundation
@testable import AnxietyWatchKit

@Suite("Oura OAuth Utils Tests")
struct OuraOAuthUtilsTests {
    @Test("authorizeURL constructs correct URL")
    func testAuthorizeURL() throws {
        let url = try #require(OuraOAuthUtils.authorizeURL(
            clientID: "test_client",
            redirectURI: "app://callback",
            scopes: ["email", "personal"],
            state: "test_state"
        ))

        #expect(url.scheme == "https")
        #expect(url.host == "cloud.ouraring.com")
        #expect(url.path == "/oauth/authorize")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try #require(components.queryItems)

        #expect(queryItems.contains { $0.name == "client_id" && $0.value == "test_client" })
        #expect(queryItems.contains { $0.name == "redirect_uri" && $0.value == "app://callback" })
        #expect(queryItems.contains { $0.name == "response_type" && $0.value == "code" })
        #expect(queryItems.contains { $0.name == "scope" && $0.value == "email personal" })
        #expect(queryItems.contains { $0.name == "state" && $0.value == "test_state" })
    }

    @Test("authorizationCode extracts the code when state matches")
    func testAuthorizationCodeValid() throws {
        let url = try #require(URL(string: "app://callback?code=abc123&state=xyz"))
        let code = try OuraOAuthUtils.authorizationCode(fromCallback: url, expectedState: "xyz")
        #expect(code == "abc123")
    }

    @Test("authorizationCode rejects a state mismatch (CSRF guard)")
    func testAuthorizationCodeStateMismatch() throws {
        let url = try #require(URL(string: "app://callback?code=abc123&state=WRONG"))
        #expect(throws: OuraOAuthError.stateMismatch) {
            try OuraOAuthUtils.authorizationCode(fromCallback: url, expectedState: "xyz")
        }
    }

    @Test("authorizationCode rejects a missing/empty code")
    func testAuthorizationCodeMissingCode() throws {
        let url = try #require(URL(string: "app://callback?state=xyz"))
        #expect(throws: OuraOAuthError.missingAuthorizationCode) {
            try OuraOAuthUtils.authorizationCode(fromCallback: url, expectedState: "xyz")
        }
    }

    @Test("tokenExchangeBody contains all required grant fields")
    func testTokenExchangeBody() throws {
        let body = try #require(OuraOAuthUtils.tokenExchangeBody(
            code: "C", clientID: "ID", clientSecret: "SECRET", redirectURI: "app://cb"))
        var comps = URLComponents()
        comps.query = body
        let items = try #require(comps.queryItems)
        #expect(items.contains { $0.name == "grant_type" && $0.value == "authorization_code" })
        #expect(items.contains { $0.name == "code" && $0.value == "C" })
        #expect(items.contains { $0.name == "client_id" && $0.value == "ID" })
        #expect(items.contains { $0.name == "client_secret" && $0.value == "SECRET" })
        #expect(items.contains { $0.name == "redirect_uri" && $0.value == "app://cb" })
    }

    @Test("decodeTokenResponse decodes and calculates expiresAt")
    func testDecodeTokenResponse() throws {
        let json = Data("""
        {
            "access_token": "acc_123",
            "refresh_token": "ref_456",
            "expires_in": 3600,
            "token_type": "Bearer"
        }
        """.utf8)

        let now = Date(timeIntervalSince1970: 100000)
        let token = try OuraOAuthUtils.decodeTokenResponse(data: json, date: now)

        #expect(token.accessToken == "acc_123")
        #expect(token.refreshToken == "ref_456")
        #expect(token.tokenType == "Bearer")
        #expect(abs(token.expiresAt.timeIntervalSince1970 - 103600) < 0.001)
    }
}
