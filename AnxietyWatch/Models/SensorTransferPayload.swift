// AnxietyWatch/Models/SensorTransferPayload.swift
import Foundation

/// JSON-serializable payload for watch → iPhone sensor data transfer.
struct SensorTransferPayload: Codable {

    struct SpectrogramDTO: Codable {
        let id: UUID
        let timestamp: Date
        let tremorBandPower: Double
        let breathingBandPower: Double
        let fidgetBandPower: Double
        let activityLevel: Double
        let sensorSessionID: UUID?

        init(from model: AccelSpectrogram) {
            self.id = model.id
            self.timestamp = model.timestamp
            self.tremorBandPower = model.tremorBandPower
            self.breathingBandPower = model.breathingBandPower
            self.fidgetBandPower = model.fidgetBandPower
            self.activityLevel = model.activityLevel
            self.sensorSessionID = model.sensorSessionID
        }
    }

    struct BreathingRateDTO: Codable {
        let id: UUID
        let timestamp: Date
        let breathsPerMinute: Double
        let confidence: Double
        let source: String
        let sensorSessionID: UUID?

        init(from model: DerivedBreathingRate) {
            self.id = model.id
            self.timestamp = model.timestamp
            self.breathsPerMinute = model.breathsPerMinute
            self.confidence = model.confidence
            self.source = model.source
            self.sensorSessionID = model.sensorSessionID
        }
    }

    struct HRVDTO: Codable {
        let id: UUID
        let timestamp: Date
        let rmssd: Double
        let sdnn: Double
        let pnn50: Double
        let lfPower: Double
        let hfPower: Double
        let lfHfRatio: Double
        let sensorSessionID: UUID?

        init(from model: HRVReading) {
            self.id = model.id
            self.timestamp = model.timestamp
            self.rmssd = model.rmssd
            self.sdnn = model.sdnn
            self.pnn50 = model.pnn50
            self.lfPower = model.lfPower
            self.hfPower = model.hfPower
            self.lfHfRatio = model.lfHfRatio
            self.sensorSessionID = model.sensorSessionID
        }
    }

    let spectrograms: [SpectrogramDTO]
    let breathingRates: [BreathingRateDTO]
    let hrvReadings: [HRVDTO]
}
