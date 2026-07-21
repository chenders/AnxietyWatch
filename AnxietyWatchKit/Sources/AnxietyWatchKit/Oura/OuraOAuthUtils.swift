import Foundation

/// Failures in the pure OAuth callback/exchange helpers. `LocalizedError` so the
/// settings alert shows a meaningful message instead of a generic system string.
public enum OuraOAuthError: LocalizedError, Equatable {
    case missingAuthorizationCode
    case stateMismatch

    public var errorDescription: String? {
        switch self {
        case .missingAuthorizationCode:
            return "Oura did not return an authorization code."
        case .stateMismatch:
            return "Oura authentication failed a security check (state mismatch)."
        }
    }
}

public enum OuraOAuthUtils {
    public static func authorizeURL(clientID: String, redirectURI: String, scopes: [String], state: String) -> URL? {
        var components = URLComponents(string: "https://cloud.ouraring.com/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    public struct TokenResponse: Decodable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresIn: TimeInterval
        public let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    public static func decodeTokenResponse(data: Data, date: Date = Date()) throws -> OuraTokenStore.Token {
        let decoder = JSONDecoder()
        let resp = try decoder.decode(TokenResponse.self, from: data)
        let expiresAt = date.addingTimeInterval(resp.expiresIn)
        return OuraTokenStore.Token(
            accessToken: resp.accessToken,
            refreshToken: resp.refreshToken,
            expiresAt: expiresAt,
            tokenType: resp.tokenType
        )
    }

    /// Extract and CSRF-validate the authorization code from the OAuth callback
    /// URL. The `state` is checked FIRST: a returned state that doesn't match the
    /// one we sent is a potential CSRF/replay and is rejected before the code is
    /// even read. Throws rather than returning nil so the caller surfaces *why*.
    public static func authorizationCode(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let returnedState = items.first { $0.name == "state" }?.value
        guard returnedState == expectedState else { throw OuraOAuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OuraOAuthError.missingAuthorizationCode
        }
        return code
    }

    /// The form-encoded body for the authorization-code token exchange. Pure so
    /// the outgoing request shape is unit-testable without touching the network.
    public static func tokenExchangeBody(code: String, clientID: String,
                                         clientSecret: String, redirectURI: String) -> String? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        return components.query
    }
}
