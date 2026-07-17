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

// MARK: - Resilience

public struct OuraResilienceResponse: Codable, Sendable {
    public let data: [OuraResilienceData]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraResilienceData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let level: String
    public let contributors: OuraResilienceContributors?

    enum CodingKeys: String, CodingKey {
        case id, day, level, contributors
    }
}

public struct OuraResilienceContributors: Codable, Sendable {
    public let sleepRecovery: Int?
    public let daytimeRecovery: Int?
    public let stress: Int?

    enum CodingKeys: String, CodingKey {
        case sleepRecovery = "sleep_recovery"
        case daytimeRecovery = "daytime_recovery"
        case stress
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

// MARK: - Cardiovascular Age

public struct OuraCardiovascularAgeResponse: Codable, Sendable {
    public let data: [OuraCardiovascularAgeData]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraCardiovascularAgeData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let vascularAge: Double?
    public let pulseWaveVelocity: Double?

    enum CodingKeys: String, CodingKey {
        case id, day
        case vascularAge = "vascular_age"
        case pulseWaveVelocity = "pulse_wave_velocity"
    }
}

// MARK: - VO2 Max

public struct OuraVO2MaxResponse: Codable, Sendable {
    public let data: [OuraVO2MaxData]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraVO2MaxData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let vo2Max: Double?

    enum CodingKeys: String, CodingKey {
        case id, day
        case vo2Max = "vo2_max"
    }
}

// MARK: - Sleep Detail

public struct OuraSleepDetailResponse: Codable, Sendable {
    public let data: [OuraSleepDetailData]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraSleepDetailData: Codable, Sendable, Identifiable {
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
    // New detailed fields
    public let hypnogram: String?
    public let hrvSeries: [Double]?
    public let respiratoryRate: Double?
    public let latency: Int?

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
        case hypnogram
        case hrvSeries = "hrv_series"
        case respiratoryRate = "respiratory_rate"
        case latency
    }
}

// MARK: - Daily SpO2

public struct OuraDailySpO2Response: Codable, Sendable {
    public let data: [OuraDailySpO2Data]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraDailySpO2Data: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let averageSpO2: Double?
    public let breathingDisturbanceIndex: Double?

    enum CodingKeys: String, CodingKey {
        case id, day
        case averageSpO2 = "average_spo2"
        case breathingDisturbanceIndex = "breathing_disturbance_index"
    }
}

// MARK: - Daily Activity

public struct OuraDailyActivityResponse: Codable, Sendable {
    public let data: [OuraDailyActivityData]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextToken = "next_token"
    }
}

public struct OuraDailyActivityData: Codable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let met: Double?
    public let steps: Int?
    public let activityClasses: [OuraActivityClass]?

    enum CodingKeys: String, CodingKey {
        case id, day, met, steps
        case activityClasses = "class_5_min"
    }
}

public struct OuraActivityClass: Codable, Sendable {
    public let activity: String?
    public let endTime: String?
    public let met: Double?
    public let startTime: String?

    enum CodingKeys: String, CodingKey {
        case activity
        case endTime = "end_time"
        case met
        case startTime = "start_time"
    }
}