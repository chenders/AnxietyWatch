import Foundation
import SwiftData

/// Static helpers over `MonitoringSession`/`CNSRiskSampleRecord` so the
/// insert/prune/ratchet logic stays testable without standing up
/// `CNSMonitoringCoordinator` (Task 6). Local-only tables (plan decision 8)
/// — see `MonitoringSession`'s doc comment.
enum MonitoringSessionStore {

    /// Creates a `CNSRiskSampleRecord`, links it to `session`, inserts it
    /// into `context`, and ratchets `session.peakTier` via `recordTier`.
    /// `contributions` is JSON-encoded into the record's `contributionsData`
    /// (see `CNSContributionRecord`).
    @discardableResult
    static func insertSample(
        timestamp: Date,
        riskScore: Double?,
        tier: CNSAlertTier,
        canAssess: Bool,
        contributions: [CNSContributionRecord] = [],
        into session: MonitoringSession,
        context: ModelContext
    ) -> CNSRiskSampleRecord {
        let record = CNSRiskSampleRecord(
            timestamp: timestamp,
            riskScore: riskScore,
            tier: tier.rawValue,
            canAssess: canAssess
        )
        record.contributions = contributions
        record.session = session
        if session.samples == nil {
            session.samples = []
        }
        session.samples?.append(record)
        context.insert(record)
        recordTier(tier, on: session)
        return record
    }

    /// Ratchets `session.peakTier` up to `tier` if `tier` is higher; never
    /// lowers it. `peakTier` records the worst tier a session ever reached
    /// (a session-summary fact for Phase 3's history view), independent of
    /// the tier machine later clearing back down.
    static func recordTier(_ tier: CNSAlertTier, on session: MonitoringSession) {
        if tier.rawValue > session.peakTier {
            session.peakTier = tier.rawValue
        }
    }

    /// Deletes persisted `CNSRiskSampleRecord`s with `timestamp < cutoff`,
    /// with one safety-net exception: a sample less than
    /// `CNSMonitoringConstants.activeSessionProtectedWindow` old (relative
    /// to `now`) that belongs to a still-active (`endedAt == nil`) session
    /// is never pruned, no matter how aggressive `cutoff` is. That window
    /// feeds the live rolling-buffer / Phase 3 "current session" view, which
    /// must never silently lose its most recent data.
    ///
    /// Production callers (the coordinator, Task 6) pass
    /// `cutoff = now - CNSMonitoringConstants.sampleRetention`; the two
    /// parameters are independent so tests can exercise the safety net with
    /// a tighter cutoff than real retention ever produces.
    static func prune(before cutoff: Date, now: Date, in context: ModelContext) throws {
        let protectedSince = now.addingTimeInterval(-CNSMonitoringConstants.activeSessionProtectedWindow)
        let candidates = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        for record in candidates where record.timestamp < cutoff {
            if let session = record.session, session.endedAt == nil, record.timestamp >= protectedSince {
                continue
            }
            context.delete(record)
        }
    }
}
