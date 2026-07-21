import Foundation

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
}
