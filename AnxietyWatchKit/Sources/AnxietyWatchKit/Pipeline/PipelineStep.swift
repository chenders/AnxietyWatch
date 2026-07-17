import Foundation

/// The pure compute core of the CNS detection pipeline (Spec §4.1).
///
/// PURITY CONTRACT — `step` MUST be a pure function of its inputs:
/// no wall-clock reads, no sleeping, no dispatch, no singletons, no
/// notification/session APIs. All time arrives as `tMs` values inside events
/// (preferred) or via the injected `clock`. This contract is enforced by the
/// purity lint test (`testPipelineHasNoImpureReferences`), which scans every
/// file in this directory for banned symbols.
public struct PipelineStep {
    /// Hysteresis window: a tier downgrade requires 30 s past the last change.
    static let hysteresisMs: Int64 = 30_000
    /// Staleness window for `.tick`: no samples within 60 s → decay to normal.
    static let stalenessMs: Int64 = 60_000
    /// Gaps longer than 5 minutes are surfaced to the user.
    static let gapNotifyThresholdMs: Int64 = 5 * 60 * 1_000
    /// SpO2 signal-quality floor; below this the reading can't be trusted for
    /// alerting (it is still recorded in the ring).
    static let spo2MinSignalQuality = 5

    /// Pure step function. No side effects; no external time; no globals.
    /// ALL timing comes from event `tMs` values — there is deliberately no
    /// clock parameter (YAGNI; a dead injected clock invites someone to read
    /// `.now` and silently break determinism). If future logic genuinely
    /// needs now-relative staleness, reintroduce a properly injected
    /// deterministic clock alongside test coverage that uses it.
    /// - Parameters:
    ///   - state: current pipeline state.
    ///   - event: sensor sample, tick, or data gap.
    /// - Returns: (newState, commands) where commands is the deterministic
    ///   list of alerts to emit for this step. The CNSMonitoringCoordinator
    ///   (T27) is the only impure interpreter.
    public static func step(
        _ state: PipelineState,
        _ event: SensorEvent
    ) -> (PipelineState, [AlertCommand]) {
        var state = state
        var commands: [AlertCommand] = []

        switch event {
        case .hr(let tMs, let bpm):
            state.hrRing.push(PipelineSample(tMs: tMs, value: Double(bpm)))
            let target: AlertTier =
                (bpm < state.thresholds.hrMin || bpm > state.thresholds.hrMax) ? .warning : .normal
            applyTier(target, at: tMs, state: &state, commands: &commands,
                      escalationMessage: "Heart rate \(bpm) BPM outside \(state.thresholds.hrMin)–\(state.thresholds.hrMax)")

        case .spo2(let tMs, let percent, let signalQuality):
            state.spo2Ring.push(PipelineSample(tMs: tMs, value: Double(percent)))
            // Bad signal: record the reading but suppress any tier change.
            guard signalQuality >= spo2MinSignalQuality else { break }
            let target: AlertTier
            if percent < state.thresholds.spo2Alert {
                target = .critical
            } else if percent < state.thresholds.spo2Warn {
                target = .warning
            } else {
                target = .normal
            }
            applyTier(target, at: tMs, state: &state, commands: &commands,
                      escalationMessage: "SpO2 \(percent)% below threshold")

        case .hrv(let tMs, let sdnnMs):
            state.hrvRing.push(PipelineSample(tMs: tMs, value: sdnnMs))
            let target: AlertTier = sdnnMs < state.thresholds.hrvLowSDNN ? .advisory : .normal
            applyTier(target, at: tMs, state: &state, commands: &commands,
                      escalationMessage: "HRV SDNN \(sdnnMs) ms below \(state.thresholds.hrvLowSDNN) ms")

        case .accel(let tMs, let magnitude):
            state.accelRing.push(PipelineSample(tMs: tMs, value: magnitude))
            let target: AlertTier = magnitude > state.thresholds.accelSumHigh ? .advisory : .normal
            applyTier(target, at: tMs, state: &state, commands: &commands,
                      escalationMessage: "Sustained high movement (\(magnitude))")

        case .dataGap(let range):
            // Drop ring contents covered by the gap — they describe a window
            // that no longer has trustworthy continuity.
            state.hrRing.removeAll { range.contains($0.tMs) }
            state.spo2Ring.removeAll { range.contains($0.tMs) }
            state.hrvRing.removeAll { range.contains($0.tMs) }
            state.accelRing.removeAll { range.contains($0.tMs) }
            state.lastGapEndMs = range.upperBound

            let spanMs = range.upperBound - range.lowerBound
            if spanMs > gapNotifyThresholdMs {
                // No .info tier exists — advisory is the lowest user-visible one.
                commands.append(.notify(tier: .advisory,
                                        message: "Monitoring gap: \(spanMs / 60_000) min without data"))
            }

        case .tick(let tMs):
            // Staleness decay: with no fresh samples in any ring, an elevated
            // tier can't be substantiated — decay to normal (with hysteresis).
            let latestSample = [
                state.hrRing.elements.last?.tMs,
                state.spo2Ring.elements.last?.tMs,
                state.hrvRing.elements.last?.tMs,
                state.accelRing.elements.last?.tMs,
            ].compactMap { $0 }.max()

            let stale = latestSample.map { tMs - $0 >= stalenessMs } ?? true
            if stale && state.currentAlertTier != .normal {
                applyTier(.normal, at: tMs, state: &state, commands: &commands,
                          escalationMessage: "")
            }
        }

        return (state, commands)
    }

    // MARK: - Tier transitions

    private static func rank(_ tier: AlertTier) -> Int {
        switch tier {
        case .normal: return 0
        case .advisory: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    /// Applies a per-event target tier with transition-only command emission:
    /// - Upgrades happen immediately and reset the hysteresis anchor.
    /// - Downgrades require >= 30 s since the last change AND the fresh signal
    ///   that produced `target` (the caller only invokes this from an event).
    /// - Equal tier: no state change, no commands.
    private static func applyTier(
        _ target: AlertTier,
        at tMs: Int64,
        state: inout PipelineState,
        commands: inout [AlertCommand],
        escalationMessage: String
    ) {
        let current = state.currentAlertTier

        if rank(target) > rank(current) {
            state.currentAlertTier = target
            state.hysteresisAnchorMs = tMs
            commands.append(.notify(tier: target, message: escalationMessage))
            if target == .critical {
                commands.append(.haptic(pattern: .failure))
            }
        } else if rank(target) < rank(current) {
            let anchorOK = state.hysteresisAnchorMs.map { tMs - $0 >= hysteresisMs } ?? true
            if anchorOK {
                state.currentAlertTier = target
                state.hysteresisAnchorMs = tMs
                commands.append(.notify(tier: target, message: "Condition improved"))
            }
        }
        // Equal tier: transition-only emission — nothing to do.
    }
}
