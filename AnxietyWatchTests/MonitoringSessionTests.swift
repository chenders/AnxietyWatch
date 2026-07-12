import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Covers the local-only monitoring-session persistence layer (spec §6,
/// plan decision 8): `MonitoringSession` + `CNSRiskSampleRecord` round-trip
/// through `TestHelpers.makeFullContainer()`, cascade delete, the
/// `MonitoringSessionStore` insert/prune/ratchet helpers, and the "never
/// prune the current un-ended session's last hour" safety net. These models
/// are registered in both SwiftData Schema lists but deliberately absent
/// from DataExporter/SyncService/RestoreFromServer (HealthSample precedent).
@MainActor
struct MonitoringSessionTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func hours(_ count: Double) -> TimeInterval { count * 3600 }
    private func minutes(_ count: Double) -> TimeInterval { count * 60 }

    private func makeSession(
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        activationTriggers: [String] = ["manual"],
        companionPresent: Bool = true
    ) -> MonitoringSession {
        MonitoringSession(
            startedAt: startedAt ?? t0,
            endedAt: endedAt,
            activationTriggers: activationTriggers,
            companionPresent: companionPresent
        )
    }

    // MARK: - Basic persistence

    @Test("MonitoringSession round-trips through makeFullContainer")
    func sessionRoundTrips() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = makeSession()
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MonitoringSession>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.activationTriggers == ["manual"])
        #expect(fetched.first?.companionPresent == true)
        #expect(fetched.first?.peakTier == CNSAlertTier.clear.rawValue)
        #expect(fetched.first?.endedAt == nil)
        #expect(fetched.first?.endReason == nil)
    }

    // MARK: - Sample insertion

    @Test("MonitoringSessionStore.insertSample appends a sample and encodes contributions")
    func insertSampleAppendsAndEncodesContributions() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = makeSession()
        context.insert(session)

        let contributions = [
            CNSContributionRecord(kind: "spo2", source: "emayOximeter", severity: 0.4, confidence: 0.9),
        ]
        let record = MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(minutes(1)),
            riskScore: 0.42,
            tier: .watch,
            canAssess: true,
            contributions: contributions,
            into: session,
            context: context
        )
        try context.save()

        #expect(session.samples?.count == 1)
        #expect(record.tier == CNSAlertTier.watch.rawValue)
        #expect(record.canAssess == true)
        #expect(abs((record.riskScore ?? -1) - 0.42) < 0.001)
        #expect(record.session?.id == session.id)
        #expect(record.contributions == contributions)

        let fetchedSamples = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(fetchedSamples.count == 1)
    }

    @Test("insertSample with nil riskScore persists insufficientData as nil, not a fabricated value")
    func insertSampleAllowsNilRiskScore() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = makeSession()
        context.insert(session)

        let record = MonitoringSessionStore.insertSample(
            timestamp: t0, riskScore: nil, tier: .clear, canAssess: false, into: session, context: context
        )
        try context.save()

        #expect(record.riskScore == nil)
        #expect(record.canAssess == false)
    }

    // MARK: - peakTier ratchet

    @Test("recordTier ratchets peakTier up but never down")
    func recordTierRatchetsUpOnly() {
        let session = makeSession()
        #expect(session.peakTier == CNSAlertTier.clear.rawValue)

        MonitoringSessionStore.recordTier(.watch, on: session)
        #expect(session.peakTier == CNSAlertTier.watch.rawValue)

        MonitoringSessionStore.recordTier(.klaxon, on: session)
        #expect(session.peakTier == CNSAlertTier.klaxon.rawValue)

        // A later drop back to .clear (tier machine clearing) must NOT lower
        // the session's recorded peak — peakTier is "worst reached," a
        // session-summary fact, not the current tier.
        MonitoringSessionStore.recordTier(.clear, on: session)
        #expect(session.peakTier == CNSAlertTier.klaxon.rawValue)

        MonitoringSessionStore.recordTier(.confirm, on: session)
        #expect(session.peakTier == CNSAlertTier.klaxon.rawValue)
    }

    // MARK: - Cascade delete

    @Test("Deleting a MonitoringSession cascades to its CNSRiskSampleRecords")
    func deleteSessionCascadesToSamples() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let session = makeSession()
        context.insert(session)
        MonitoringSessionStore.insertSample(
            timestamp: t0, riskScore: 0.1, tier: .clear, canAssess: true, into: session, context: context
        )
        MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(minutes(1)), riskScore: 0.2, tier: .watch,
            canAssess: true, into: session, context: context
        )
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CNSRiskSampleRecord>()) == 2)

        context.delete(session)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<MonitoringSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CNSRiskSampleRecord>()).isEmpty)
    }

    // MARK: - Prune: standard retention

    @Test("prune(before:now:) removes samples older than the cutoff, keeps newer ones")
    func pruneRemovesOlderThanCutoff() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // An ENDED session so the "current session" safety net never applies
        // in this test — isolates the plain retention-cutoff behavior.
        let session = makeSession(endedAt: t0.addingTimeInterval(hours(1)))
        context.insert(session)
        let old = MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(-hours(25)), riskScore: 0.1, tier: .clear,
            canAssess: true, into: session, context: context
        )
        let recent = MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(-hours(1)), riskScore: 0.1, tier: .clear,
            canAssess: true, into: session, context: context
        )
        try context.save()
        _ = old
        _ = recent

        let cutoff = t0.addingTimeInterval(-CNSMonitoringConstants.sampleRetention)
        try MonitoringSessionStore.prune(before: cutoff, now: t0, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.timestamp == t0.addingTimeInterval(-hours(1)))
    }

    // MARK: - Prune: never the current session's last hour

    @Test("prune never removes the current un-ended session's last-hour samples, even under an aggressive cutoff")
    func pruneProtectsCurrentSessionLastHour() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Still active — no endedAt.
        let activeSession = makeSession(endedAt: nil)
        context.insert(activeSession)
        // Halfway into the protected window — derived from the constant so a
        // future tuning of activeSessionProtectedWindow keeps this fixture
        // inside the window it exists to probe.
        let insideWindow = CNSMonitoringConstants.activeSessionProtectedWindow / 2
        let protectedSample = MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(-insideWindow), riskScore: 0.1, tier: .clear,
            canAssess: true, into: activeSession, context: context
        )
        try context.save()
        _ = protectedSample

        // An aggressive cutoff — far more recent than the sampleRetention-
        // derived cutoff would ever be — deliberately chosen so the standard
        // "older than retention" rule alone would delete this sample. Only
        // the current-un-ended-session's-last-hour safety net can save it.
        let aggressiveCutoff = t0.addingTimeInterval(-minutes(1))
        try MonitoringSessionStore.prune(before: aggressiveCutoff, now: t0, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(remaining.count == 1, "the active session's last-hour sample must survive an aggressive cutoff")
    }

    @Test("prune's safety net is specific to un-ended sessions: an ended session's recent sample still prunes")
    func pruneDoesNotProtectEndedSessions() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Ended — the safety net must not apply here.
        let endedSession = makeSession(endedAt: t0.addingTimeInterval(-minutes(20)))
        context.insert(endedSession)
        MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(-minutes(30)), riskScore: 0.1, tier: .clear,
            canAssess: true, into: endedSession, context: context
        )
        try context.save()

        let aggressiveCutoff = t0.addingTimeInterval(-minutes(1))
        try MonitoringSessionStore.prune(before: aggressiveCutoff, now: t0, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(remaining.isEmpty, "an ENDED session gets no last-hour protection")
    }

    @Test("prune's safety net only covers the last hour, not the whole active session")
    func pruneProtectionIsBoundedToOneHour() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let activeSession = makeSession(endedAt: nil)
        context.insert(activeSession)
        // Twice the protected window's age — derived from the constant so a
        // future tuning of activeSessionProtectedWindow keeps this fixture
        // outside the window — must be prunable even though the session is
        // still active.
        let outsideWindow = CNSMonitoringConstants.activeSessionProtectedWindow * 2
        MonitoringSessionStore.insertSample(
            timestamp: t0.addingTimeInterval(-outsideWindow), riskScore: 0.1, tier: .clear,
            canAssess: true, into: activeSession, context: context
        )
        try context.save()

        let aggressiveCutoff = t0.addingTimeInterval(-minutes(1))
        try MonitoringSessionStore.prune(before: aggressiveCutoff, now: t0, in: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<CNSRiskSampleRecord>())
        #expect(remaining.isEmpty, "samples beyond the 1h protected window still prune despite the active session")
    }

    // MARK: - Companion log Codable round-trip

    @Test("companionLog encodes and decodes through companionLogData")
    func companionLogRoundTrips() {
        let session = makeSession()
        #expect(session.companionLog.isEmpty)

        session.companionLog = [
            CompanionLogEntry(timestamp: t0, present: true),
            CompanionLogEntry(timestamp: t0.addingTimeInterval(minutes(10)), present: false),
        ]

        #expect(session.companionLog.count == 2)
        #expect(session.companionLog.first?.present == true)
        #expect(session.companionLog.last?.present == false)
    }
}
