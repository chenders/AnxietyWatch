import Foundation
import SwiftData

/// One arm→disarm run of the CNS-depression monitor (spec §6). Local-only
/// (`HealthSample` precedent, klaxon-phase2 plan decision 8): registered in
/// both SwiftData `Schema` lists (`AnxietyWatchApp.swift`,
/// `TestHelpers.makeFullContainer`) but never touched by
/// `DataExporter`/`SyncService`/`RestoreFromServer` — session/sample history
/// stays on-device. The coordinator (Task 6) owns the lifecycle
/// (start/end/tier edges/device-loss handling); Phase 3's ~1-hour view reads
/// `samples`.
@Model
final class MonitoringSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    /// Raw `CNSMonitoringCoordinator.ActivationTrigger` values active at
    /// start (e.g. ["manual", "doseWindow"]). Triggers are independent — a
    /// session ends only when this set becomes empty, never merely because
    /// one trigger (e.g. a dose window) expired while another is still
    /// active (spec §14.3).
    var activationTriggers: [String]
    /// §6: per-start, re-markable mid-session. The coordinator's
    /// `setCompanionPresent` (Task 6) flips this without resetting the
    /// pipeline's escalation/sustain state (plan decision 7); every flip
    /// also appends a `CompanionLogEntry` via the `companionLog` accessor
    /// below.
    var companionPresent: Bool
    /// JSON-encoded `[CompanionLogEntry]` history of companion re-marks —
    /// small and bounded (one entry per manual re-mark in a session). Decode
    /// via `companionLog`.
    var companionLogData: Data?
    /// Raw `CNSMonitoringCoordinator.EndReason`: "manual", "windowExpired",
    /// "deviceLoss", or "appTerminated". nil while the session is still
    /// active (`endedAt == nil`).
    var endReason: String?
    /// Highest `CNSAlertTier.rawValue` reached during the session — the
    /// session-summary field Phase 3's history view surfaces. Ratchets up
    /// only; see `MonitoringSessionStore.recordTier(_:on:)`.
    var peakTier: Int
    /// Cascade delete: removing a session removes every risk sample it
    /// owns — a `CNSRiskSampleRecord` is meaningless without its session.
    @Relationship(deleteRule: .cascade, inverse: \CNSRiskSampleRecord.session)
    var samples: [CNSRiskSampleRecord]?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        activationTriggers: [String],
        companionPresent: Bool,
        companionLogData: Data? = nil,
        endReason: String? = nil,
        peakTier: Int = CNSAlertTier.clear.rawValue
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activationTriggers = activationTriggers
        self.companionPresent = companionPresent
        self.companionLogData = companionLogData
        self.endReason = endReason
        self.peakTier = peakTier
        self.samples = nil
    }
}

/// One entry in a session's companion-presence re-mark history (spec §6).
/// Small, bounded, JSON-encoded into `MonitoringSession.companionLogData` —
/// a `Codable` mirror kept separate from any pipeline/coordinator type so
/// the persisted shape never has to change when those types do.
struct CompanionLogEntry: Codable, Equatable, Sendable {
    let timestamp: Date
    let present: Bool
}

extension MonitoringSession {
    /// Decodes `companionLogData`; `[]` when nil or (in principle)
    /// corrupt — a persisted-data read must never crash or throw.
    var companionLog: [CompanionLogEntry] {
        get {
            guard let data = companionLogData else { return [] }
            return (try? JSONDecoder().decode([CompanionLogEntry].self, from: data)) ?? []
        }
        set {
            companionLogData = try? JSONEncoder().encode(newValue)
        }
    }
}
