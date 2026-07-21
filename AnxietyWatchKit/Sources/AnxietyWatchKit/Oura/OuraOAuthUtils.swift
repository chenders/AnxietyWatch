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
        public let access_token: String
        public let refresh_token: String
        public let expires_in: TimeInterval
        public let token_type: String
    }

    public static func decodeTokenResponse(data: Data, date: Date = Date()) throws -> OuraTokenStore.Token {
        let decoder = JSONDecoder()
        let resp = try decoder.decode(TokenResponse.self, from: data)
        let expiresAt = date.addingTimeInterval(resp.expires_in)
        return OuraTokenStore.Token(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token,
            expiresAt: expiresAt,
            tokenType: resp.token_type
        )
    }
}
