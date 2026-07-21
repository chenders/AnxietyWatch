import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OuraAPIError: Error, Equatable {
    case unauthorized
    case rateLimited(tier: String?)
    case invalidResponse(statusCode: Int)
    case decodingFailed(Error)
    case networkError(Error)
    
    public static func ==(lhs: OuraAPIError, rhs: OuraAPIError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized): return true
        case (.rateLimited(let t1), .rateLimited(let t2)): return t1 == t2
        case (.invalidResponse(let c1), .invalidResponse(let c2)): return c1 == c2
        case (.decodingFailed, .decodingFailed), (.networkError, .networkError): return true
        default: return false
        }
    }
}

public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

/// Actor responsible for fetching data from the Oura V2 Cloud API.
public actor OuraAPIClient {
    private let baseURL = URL(string: "https://api.ouraring.com/v2/usercollection")!
    private var accessToken: String?
    private let session: URLSessionProtocol
    private let decoder: JSONDecoder
    
    public init(session: URLSessionProtocol = URLSession.shared) {
        self.session = session
        let decoder = JSONDecoder()
        // Oura timestamps look like "2023-11-20T21:00:00+00:00"
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }
    
    public func setAccessToken(_ token: String) {
        self.accessToken = token
    }
    
    public func fetchIBI(startDate: String, endDate: String) async throws -> [OuraIBIData] {
        return try await fetch(endpoint: "interbeat_interval", startDate: startDate, endDate: endDate, responseType: OuraIBIResponse.self).data
    }
    
    public func fetchSleep(startDate: String, endDate: String) async throws -> [OuraSleepData] {
        return try await fetch(endpoint: "sleep", startDate: startDate, endDate: endDate, responseType: OuraSleepResponse.self).data
    }
    
    public func fetchReadiness(startDate: String, endDate: String) async throws -> [OuraReadinessData] {
        return try await fetch(endpoint: "daily_readiness", startDate: startDate, endDate: endDate, responseType: OuraReadinessResponse.self).data
    }
    
    public func fetchStress(startDate: String, endDate: String) async throws -> [OuraStressData] {
        return try await fetch(endpoint: "daily_stress", startDate: startDate, endDate: endDate, responseType: OuraStressResponse.self).data
    }

    public func fetchResilience(startDate: String, endDate: String) async throws -> [OuraResilienceData] {
        return try await fetch(endpoint: "daily_resilience", startDate: startDate, endDate: endDate, responseType: OuraResilienceResponse.self).data
    }
    
    // MARK: - New API methods
    
    public func postTokenToServer(baseURL: String, apiKey: String, token: OuraTokenStore.Token) async throws {
        struct AuthPayload: Encodable {
            let access_token: String
            let refresh_token: String
            let expires_at: String
        }
        
        guard let url = URL(string: baseURL)?.appendingPathComponent("api/oura/auth") else {
            throw OuraAPIError.invalidResponse(statusCode: 400)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let formatter = ISO8601DateFormatter()
        let payload = AuthPayload(
            access_token: token.accessToken,
            refresh_token: token.refreshToken,
            expires_at: formatter.string(from: token.expiresAt)
        )
        
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OuraAPIError.invalidResponse(statusCode: 0)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OuraAPIError.invalidResponse(statusCode: httpResponse.statusCode)
        }
    }
    
    public func fetchCardiovascularAge(startDate: String, endDate: String) async throws -> [OuraCardiovascularAgeData] {
        return try await fetch(endpoint: "daily_cardiovascular_age", startDate: startDate, endDate: endDate, responseType: OuraCardiovascularAgeResponse.self).data
    }
    
    public func fetchVO2Max(startDate: String, endDate: String) async throws -> [OuraVO2MaxData] {
        return try await fetch(endpoint: "vo2_max", startDate: startDate, endDate: endDate, responseType: OuraVO2MaxResponse.self).data
    }
    
    public func fetchSleepDetail(startDate: String, endDate: String) async throws -> [OuraSleepDetailData] {
        return try await fetch(endpoint: "sleep", startDate: startDate, endDate: endDate, responseType: OuraSleepDetailResponse.self).data
    }
    
    public func fetchDailySpO2(startDate: String, endDate: String) async throws -> [OuraDailySpO2Data] {
        return try await fetch(endpoint: "daily_spo2", startDate: startDate, endDate: endDate, responseType: OuraDailySpO2Response.self).data
    }
    
    public func fetchDailyActivity(startDate: String, endDate: String) async throws -> [OuraDailyActivityData] {
        return try await fetch(endpoint: "daily_activity", startDate: startDate, endDate: endDate, responseType: OuraDailyActivityResponse.self).data
    }
    
    private func fetch<T: Decodable>(endpoint: String, startDate: String, endDate: String, responseType: T.Type) async throws -> T {
        guard let token = accessToken else {
            throw OuraAPIError.unauthorized
        }
        
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate)
        ]
        
        guard let url = urlComponents.url else {
            throw OuraAPIError.invalidResponse(statusCode: 400)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OuraAPIError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OuraAPIError.invalidResponse(statusCode: 0)
        }
        
        if httpResponse.statusCode == 401 {
            throw OuraAPIError.unauthorized
        } else if httpResponse.statusCode == 429 {
            let tier = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Tier")
            throw OuraAPIError.rateLimited(tier: tier)
        } else if !(200...299).contains(httpResponse.statusCode) {
            throw OuraAPIError.invalidResponse(statusCode: httpResponse.statusCode)
        }
        
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw OuraAPIError.decodingFailed(error)
        }
    }
}