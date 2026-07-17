import Foundation

/// Pure alert-tier state machine. Given a current tier + a proposed target
/// tier + the current tMs, returns the resulting tier and any AlertCommand
/// to emit. Centralizes the "transition-only emit + 30 s hysteresis on
/// downgrade" contract that PipelineStep previously duplicated per branch —
/// one code path, one test surface, no drift.
///
/// No side effects, no external time (purity enforced by the Pipeline lint).
public struct CNSAlertTierMachine {

    public enum ProposalSource: String, Sendable, Codable {
        case perSample     // threshold cascade in PipelineStep
        case fusion        // CNSFusionEngine / PipelineStep.applyFusion
        case tickStale     // staleness-driven downgrade to .normal
        case dataGap       // gap-driven advisory
    }

    public struct Decision: Sendable, Equatable {
        public let newTier: AlertTier
        public let commands: [AlertCommand]
        public let newAnchorMs: Int64?

        public init(newTier: AlertTier, commands: [AlertCommand], newAnchorMs: Int64?) {
            self.newTier = newTier
            self.commands = commands
            self.newAnchorMs = newAnchorMs
        }
    }

    /// A tier downgrade requires this much time past the last change.
    public static let hysteresisMs: Int64 = 30_000

    /// Severity order used for upgrade/downgrade decisions.
    public static func rank(_ tier: AlertTier) -> Int {
        switch tier {
        case .normal: return 0
        case .advisory: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    /// Apply a tier proposal and return the (newTier, commands, newAnchorMs).
    /// - Upgrades always take effect immediately + set a fresh anchor at tMs.
    /// - Downgrades require (tMs - currentAnchor) >= hysteresisMs, else the
    ///   proposal is DROPPED and state is unchanged. A nil anchor means "no
    ///   hysteresis window active" (fresh state) and allows the downgrade.
    /// - Equal proposals never emit commands (transition-only).
    /// - Upgrade commands include a .notify plus a .haptic scaled to the tier
    ///   (advisory = singleTap, warning = doubleTap, critical = failure).
    public static func propose(
        currentTier: AlertTier,
        currentAnchorMs: Int64?,
        target: AlertTier,
        tMs: Int64,
        source: ProposalSource,
        messageOverride: String? = nil
    ) -> Decision {
        let currentRank = rank(currentTier)
        let targetRank = rank(target)

        if targetRank > currentRank {
            // Upgrade: immediate, fresh anchor.
            var commands: [AlertCommand] = [
                .notify(tier: target, message: messageOverride ?? upgradeMessage(source: source, target: target))
            ]
            if let haptic = upgradeHaptic(for: target) {
                commands.append(.haptic(pattern: haptic))
            }
            return Decision(newTier: target, commands: commands, newAnchorMs: tMs)
        }

        if targetRank < currentRank {
            // Downgrade: hysteresis-guarded.
            let windowMet = currentAnchorMs.map { tMs - $0 >= hysteresisMs } ?? true
            guard windowMet else {
                // Dropped — state unchanged.
                return Decision(newTier: currentTier, commands: [], newAnchorMs: currentAnchorMs)
            }
            return Decision(
                newTier: target,
                commands: [.notify(tier: target, message: messageOverride ?? "Condition improved")],
                newAnchorMs: tMs
            )
        }

        // Equal: transition-only — no emission, no state change.
        return Decision(newTier: currentTier, commands: [], newAnchorMs: currentAnchorMs)
    }

    // MARK: - Defaults

    private static func upgradeHaptic(for tier: AlertTier) -> AlertCommand.HapticPattern? {
        switch tier {
        case .normal: return nil
        case .advisory: return .singleTap
        case .warning: return .doubleTap
        case .critical: return .failure
        }
    }

    private static func upgradeMessage(source: ProposalSource, target: AlertTier) -> String {
        switch source {
        case .perSample:
            switch target {
            case .critical: return "Vital sign dropped below critical threshold"
            case .warning: return "Vital sign out of range: elevated tier"
            default: return "Vital sign threshold crossed"
            }
        case .fusion:
            return "Fusion score indicated CNS depression risk"
        case .dataGap:
            return "Monitoring gap detected"
        case .tickStale:
            // tickStale only ever proposes downgrades; this default exists for
            // exhaustiveness.
            return "Condition improved"
        }
    }
}
