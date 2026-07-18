import Foundation

/// Pure fusion of multi-signal ring data into a CNS-depression risk score.
/// No side effects, no external time — the tMs of the most recent sample per
/// ring is derived from state.
///
/// Score semantics (0.0 = healthy, 1.0 = maximum depression risk):
///   - HR trend: sustained low HR (< thresholds.hrMin) is a strong signal;
///     sustained high HR is neutral (may indicate stress not depression).
///   - HRV: low SDNN (< thresholds.hrvLowSDNN) is a moderate signal.
///   - SpO2: sustained low SpO2 (< thresholds.spo2Warn) is a strong signal.
///   - Accel: prolonged low magnitude (rest / immobility) is a mild signal
///     but only if HR is also low (fusion, not independent).
///   - Breathing: <8 or >30 BPM is a mild signal (from accel-derived rate).
/// Weights sum to 1.0.
public struct CNSFusionEngine {

    public struct FusionScore: Sendable, Equatable {
        public let overall: Double                   // 0.0 .. 1.0
        public let hrContribution: Double            // 0.0 .. 1.0
        public let hrvContribution: Double
        public let spo2Contribution: Double
        public let accelContribution: Double
        public let breathContribution: Double
        public let sampleCountsUsed: [String: Int]   // ring → n samples used
    }

    public static let weightHR: Double = 0.30
    public static let weightHRV: Double = 0.15
    public static let weightSpO2: Double = 0.35
    public static let weightAccel: Double = 0.10
    public static let weightBreath: Double = 0.10

    /// Compute a fusion score from the current PipelineState. Pure.
    public static func fuse(_ state: PipelineState) -> FusionScore {
        // Initialize sample counts
        var sampleCounts: [String: Int] = [:]
        
        // HR contribution: if hrRing has < 5 samples, contribution = 0 (insufficient data)
        let hrContribution: Double
        if state.hrRing.count < 5 {
            hrContribution = 0.0
        } else {
            // Mean of last 30 samples
            let hrElements = state.hrRing.elements
            let hrSampleCount = min(30, hrElements.count)
            sampleCounts["hr"] = hrSampleCount
            let startIndex = max(0, hrElements.count - 30)
            let last30HRSamples = Array(hrElements[startIndex..<hrElements.count])
            let hrMean = last30HRSamples.map { $0.value }.reduce(0, +) / Double(last30HRSamples.count)
            
            if hrMean < Double(state.thresholds.hrMin) {
                // If mean < thresholds.hrMin → contribution = min(1.0, (thresholds.hrMin - mean) / 20.0)
                hrContribution = min(1.0, (Double(state.thresholds.hrMin) - hrMean) / 20.0)
            } else {
                // High or normal HR is neutral (no signal)
                hrContribution = 0.0
            }
        }
        
        // HRV contribution: mean of last 10 samples
        let hrvContribution: Double
        if state.hrvRing.count < 1 {
            hrvContribution = 0.0
        } else {
            let hrvElements = state.hrvRing.elements
            let hrvSampleCount = min(10, hrvElements.count)
            sampleCounts["hrv"] = hrvSampleCount
            let startIndex = max(0, hrvElements.count - 10)
            let last10HRVSamples = Array(hrvElements[startIndex..<hrvElements.count])
            let hrvMean = last10HRVSamples.map { $0.value }.reduce(0, +) / Double(last10HRVSamples.count)
            
            // Contribution = clamp((thresholds.hrvLowSDNN - mean) / thresholds.hrvLowSDNN, 0, 1)
            if hrvMean >= state.thresholds.hrvLowSDNN {
                hrvContribution = 0.0
            } else {
                hrvContribution = max(0.0, min(1.0, (state.thresholds.hrvLowSDNN - hrvMean) / state.thresholds.hrvLowSDNN))
            }
        }
        
        // SpO2 contribution: min of last 5 samples (worst case matters)
        let spo2Contribution: Double
        if state.spo2Ring.count < 1 {
            spo2Contribution = 0.0
        } else {
            let spo2Elements = state.spo2Ring.elements
            let spo2SampleCount = min(5, spo2Elements.count)
            sampleCounts["spo2"] = spo2SampleCount
            let startIndex = max(0, spo2Elements.count - 5)
            let last5SpO2Samples = Array(spo2Elements[startIndex..<spo2Elements.count])
            let spo2Min = last5SpO2Samples.map { $0.value }.min() ?? 0.0
            
            if spo2Min < Double(state.thresholds.spo2Alert) {
                // if min < spo2Alert → 1.0
                spo2Contribution = 1.0
            } else if spo2Min < Double(state.thresholds.spo2Warn) {
                // if min < spo2Warn → 0.6
                spo2Contribution = 0.6
            } else {
                // if min >= spo2Warn → scales linearly to 0 at (spo2Warn + 5)
                let spo2WarnPlus5 = Double(state.thresholds.spo2Warn) + 5.0
                if spo2Min >= spo2WarnPlus5 {
                    spo2Contribution = 0.0
                } else {
                    spo2Contribution = (spo2WarnPlus5 - spo2Min) / 5.0
                }
            }
        }
        
        // Accel contribution: only nonzero if HR contribution > 0.3 (fusion — immobility alone isn't a signal)
        let accelContribution: Double
        if state.accelRing.count < 1 {
            accelContribution = 0.0
        } else {
            let accelElements = state.accelRing.elements
            let accelSampleCount = min(30, accelElements.count)
            sampleCounts["accel"] = accelSampleCount
            let startIndex = max(0, accelElements.count - 30)
            let last30AccelSamples = Array(accelElements[startIndex..<accelElements.count])
            let accelMean = last30AccelSamples.map { $0.value }.reduce(0, +) / Double(last30AccelSamples.count)
            
            // Only nonzero if HR contribution > 0.3 (fusion — immobility alone isn't a signal)
            if hrContribution > 0.3 && accelMean < 1.0 {
                accelContribution = min(1.0, 0.5 + (hrContribution * 0.5))
            } else {
                accelContribution = 0.0
            }
        }
        
        // Breath contribution: derived from accel timing (proxy)
        let breathContribution: Double
        if state.accelRing.count < 20 {
            breathContribution = 0.0
        } else {
            let accelElements = state.accelRing.elements
            sampleCounts["breath"] = accelElements.count
            
            // For T25 just use a placeholder — return 0 if accel ring < 20 samples, 
            // else compute breaths-per-minute from zero-crossings and scale.
            // Placeholder implementation - count sign changes above threshold to derive BPM
            var zeroCrossings = 0
            let threshold = 0.1
            
            // We need at least 2 elements to compare
            if accelElements.count >= 2 {
                for i in 1..<accelElements.count {
                    let prev = accelElements[i-1].value
                    let curr = accelElements[i].value
                    // Simple zero crossing detection (crossing above threshold)
                    if prev <= threshold && curr > threshold {
                        zeroCrossings += 1
                    }
                }
                
                // Derive BPM from count/window
                // Estimate time span from first to last sample
                if let firstTime = accelElements.first?.tMs, let lastTime = accelElements.last?.tMs {
                    let timeSpanSeconds = Double(lastTime - firstTime) / 1000.0
                    if timeSpanSeconds > 0 {
                        let breathRate = Double(zeroCrossings) * 60.0 / timeSpanSeconds
                        
                        // if BPM < thresholds.breathRateMin or > breathRateMax → 0.4, else 0
                        if breathRate < state.thresholds.breathRateMin || breathRate > state.thresholds.breathRateMax {
                            breathContribution = 0.4
                        } else {
                            breathContribution = 0.0
                        }
                    } else {
                        breathContribution = 0.0
                    }
                } else {
                    breathContribution = 0.0
                }
            } else {
                breathContribution = 0.0
            }
        }
        
        // Overall = clamp(hrC*wHR + hrvC*wHRV + spo2C*wSpO2 + accelC*wAccel + breathC*wBreath, 0, 1)
        let overall = max(0.0, min(1.0, 
            hrContribution * weightHR +
            hrvContribution * weightHRV +
            spo2Contribution * weightSpO2 +
            accelContribution * weightAccel +
            breathContribution * weightBreath
        ))
        
        return FusionScore(
            overall: overall,
            hrContribution: hrContribution,
            hrvContribution: hrvContribution,
            spo2Contribution: spo2Contribution,
            accelContribution: accelContribution,
            breathContribution: breathContribution,
            sampleCountsUsed: sampleCounts
        )
    }
}