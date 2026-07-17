import Foundation

// MARK: - Shared Enums

public enum OuraDataValidity: Int, Codable, Sendable {
    case raw = 0
    case good = 1
    case bad = 2
    case corrected = 3
    case gap1 = -1
    case gap2 = -2
}

// MARK: - Interbeat Interval (IBI)

public struct OuraIBIResponse: Codable, Sendable {
    public let data: [OuraIBIData]
    public let nextToken: String?
    
    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraIBIData: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let timestampUnix: Int64
    /// IBI in milliseconds (per official Oura docs / TS client)
    public let ibi: Int
    public let validity: OuraDataValidity?
    
    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case timestampUnix = "timestamp_unix"
        case ibi
        case validity
    }
}

// MARK: - Sleep

public struct OuraSleepResponse: Codable, Sendable {
    public let data: [OuraSleepData]
    public let nextToken: String?
    
    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraSleepData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let averageHeartRate: Double?
    public let averageHrv: Double?
    public let timeInBed: Int
    public let awakeTime: Int?
    public let deepSleepDuration: Int?
    public let lightSleepDuration: Int?
    public let remSleepDuration: Int?
    public let totalSleepDuration: Int?
    public let efficiency: Int?
    public let score: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, day
        case averageHeartRate = "average_heart_rate"
        case averageHrv = "average_hrv"
        case timeInBed = "time_in_bed"
        case awakeTime = "awake_time"
        case deepSleepDuration = "deep_sleep_duration"
        case lightSleepDuration = "light_sleep_duration"
        case remSleepDuration = "rem_sleep_duration"
        case totalSleepDuration = "total_sleep_duration"
        case efficiency, score
    }
}

// MARK: - Readiness

public struct OuraReadinessResponse: Codable, Sendable {
    public let data: [OuraReadinessData]
    public let nextToken: String?
    
    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraReadinessData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let score: Int?
    public let temperatureDeviation: Double?
    
    enum CodingKeys: String, CodingKey {
        case id, day, score
        case temperatureDeviation = "temperature_deviation"
    }
}

// MARK: - Stress

public struct OuraStressResponse: Codable, Sendable {
    public let data: [OuraStressData]
    public let nextToken: String?
    
    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraStressData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let stressHigh: Int?
    public let recoveryHigh: Int?
    public let daySummary: String?
    
    enum CodingKeys: String, CodingKey {
        case id, day
        case stressHigh = "stress_high"
        case recoveryHigh = "recovery_high"
        case daySummary = "day_summary"
    }
}
