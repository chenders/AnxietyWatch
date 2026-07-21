import Foundation
import AuthenticationServices
import UIKit
import AnxietyWatchKit

@MainActor
final class OuraOAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var authSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authenticate() async throws -> OuraTokenStore.Token {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "OuraClientID") as? String ?? ""
        let clientSecret = Bundle.main.object(forInfoDictionaryKey: "OuraClientSecret") as? String ?? ""
        let redirectURI = Bundle.main.object(forInfoDictionaryKey: "OuraRedirectURI") as? String ?? ""

        guard !clientID.isEmpty, !clientSecret.isEmpty, !redirectURI.isEmpty else {
            throw NSError(domain: "OuraOAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing Oura configuration in Info.plist"])
        }

        let scopes = ["email", "personal", "daily", "heartrate", "workout", "tag", "session", "spo2"]
        let state = UUID().uuidString

        guard let authorizeURL = OuraOAuthUtils.authorizeURL(clientID: clientID, redirectURI: redirectURI, scopes: scopes, state: state) else {
            throw URLError(.badURL)
        }

        let scheme = URL(string: redirectURI)?.scheme ?? "anxietywatch"

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            authSession = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: scheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            authSession?.presentationContextProvider = self
            authSession?.prefersEphemeralWebBrowserSession = false

            if !(authSession?.start() ?? false) {
                continuation.resume(throwing: URLError(.unknown))
            }
        }

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw URLError(.badServerResponse)
        }

        return try await exchangeCodeForToken(code: code, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI)
    }

    private func exchangeCodeForToken(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) async throws -> OuraTokenStore.Token {
        guard let url = URL(string: "https://api.ouraring.com/oauth/token") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]

        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try OuraOAuthUtils.decodeTokenResponse(data: data)
    }
}
