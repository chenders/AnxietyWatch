import Foundation

// MARK: - Oura BLE sample types

/// Samples emitted by `OuraBLEActor` and consumed by `SensorRouter` /
/// CNS pipeline. Each type maps to a measurement tag in the BLE protocol.
/// All types are `Sendable` + `Equatable` for safe actor crossing and
/// test assertions.

// MARK: IBI (heart rate variability) sample

/// Live beat-to-beat interbeat interval from the Oura Ring BLE live-HR
/// notification stream. The ring pushes one IBI per heartbeat when
/// `CAP_DAYTIME_HR` + `CAP_CONNECTED_LIVE` are enabled.
public struct OuraBLEIBISample: Sendable, Equatable {
    /// Unix timestamp (seconds since epoch).
    public let timestamp: Double
    /// Interbeat interval in milliseconds (capped at 2000 ms by the ring).
    public let ibiMs: Int
    /// Instantaneous heart rate in BPM derived from IBI: `60_000 / ibiMs`.
    public var instantHR: Double { ibiMs > 0 ? 60_000.0 / Double(ibiMs) : 0 }

    public init(timestamp: Double, ibiMs: Int) {
        self.timestamp = timestamp
        self.ibiMs = ibiMs
    }
}

// MARK: SpO2 sample

/// Single SpO2 reading from the ring. Typically collected during sleep;
/// daytime on-demand readings are possible but less frequent.
public struct OuraBLESpO2Sample: Sendable, Equatable {
    /// Unix timestamp (seconds since epoch).
    public let timestamp: Double
    /// SpO2 percentage (0–100).
    public let spo2Percent: Int
    /// Signal quality indicator (0–15, ring-internal scale).
    public let signalQuality: Int

    public init(timestamp: Double, spo2Percent: Int, signalQuality: Int) {
        self.timestamp = timestamp
        self.spo2Percent = spo2Percent
        self.signalQuality = signalQuality
    }
}

// MARK: Accelerometer sample

/// 3-axis accelerometer reading at ~50 Hz with ~20 ms latency.
/// Useful for motion classification, sleep/wake detection, and
/// respiratory-effort derivation.
public struct OuraBLEAccelSample: Sendable, Equatable {
    /// Unix timestamp (seconds since epoch).
    public let timestamp: Double
    /// X-axis acceleration in g.
    public let x: Double
    /// Y-axis acceleration in g.
    public let y: Double
    /// Z-axis acceleration in g.
    public let z: Double

    public init(timestamp: Double, x: Double, y: Double, z: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
    }
}

// MARK: Temperature sample

/// Skin temperature reading from the ring. The ring reports temperature
/// deviation from a personal baseline, not absolute temperature.
public struct OuraBLETemperatureSample: Sendable, Equatable {
    /// Unix timestamp (seconds since epoch).
    public let timestamp: Double
    /// Temperature deviation from personal baseline in °C.
    public let deviationCelsius: Double

    public init(timestamp: Double, deviationCelsius: Double) {
        self.timestamp = timestamp
        self.deviationCelsius = deviationCelsius
    }
}

// MARK: Sleep stage sample

/// Sleep stage classification produced on-ring (OSSA / OSSA 2.0 algorithm).
/// Stages are reported as the ring detects transitions.
public struct OuraBLESleepStageSample: Sendable, Equatable {
    /// Sleep stage as classified by the ring.
    public enum Stage: Int, Sendable, Equatable {
        case awake = 0
        case light = 1
        case deep  = 2
        case rem   = 3
        case unknown = -1
    }

    /// Unix timestamp (seconds since epoch).
    public let timestamp: Double
    /// Detected sleep stage.
    public let stage: Stage

    public init(timestamp: Double, stage: Stage) {
        self.timestamp = timestamp
        self.stage = stage
    }
}

// MARK: Battery sample

/// Battery status reported periodically by the ring.
public struct OuraBLEBatterySample: Sendable, Equatable {
    /// Unix timestamp (seconds since epoch).
    public let timestamp: Double
    /// Battery percentage (0–100).
    public let percent: Int
    /// Whether the ring is currently on the charger.
    public let isCharging: Bool

    public init(timestamp: Double, percent: Int, isCharging: Bool) {
        self.timestamp = timestamp
        self.percent = percent
        self.isCharging = isCharging
    }
}

// MARK: Connection state

/// Connection lifecycle events useful for diagnostics and UI state.
public enum OuraBLEConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case streaming
    case failed(OuraBLEConnectionError)
}

public enum OuraBLEConnectionError: Error, Sendable, Equatable {
    case bluetoothPoweredOff
    case ringNotFound
    case connectionTimeout
    case authFailed(reason: String)
    case keyNotProvisioned
    case featureEnableFailed
    case contentionWithOfficialApp
    case disconnectedUnexpectedly
}

// MARK: - AnySensorSample integration

extension SensorRouter.AnySensorSample {
    /// Construct from an Oura BLE IBI sample (distinct from cloud-API IBI).
    public static func ouraBLE(_ sample: OuraBLEIBISample) -> SensorRouter.AnySensorSample {
        .oura(SensorRouter.AnySensorSample.OuraIBISample(
            timestamp: sample.timestamp,
            ibiMs: sample.ibiMs,
            validity: nil  // BLE samples have no validity flag — raw from ring
        ))
    }
}
