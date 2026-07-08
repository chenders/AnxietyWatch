import Foundation
import Testing

@testable import AnxietyWatch

/// Serialized to prevent UserDefaults races when CI runs tests in parallel clones.
@Suite(.serialized)
struct DoseFollowUpManagerTests {

    /// Fixed reference point for all time-relative tests.
    /// Using ModelFactory.referenceDate avoids flaky behavior near midnight.
    private let now = ModelFactory.referenceDate

    /// Clear pending follow-ups (and any corrupt backup) before each test.
    private func clearPending() {
        UserDefaults.standard.removeObject(forKey: "pendingDoseFollowUps")
        UserDefaults.standard.removeObject(forKey: DoseFollowUpManager.corruptBackupKey)
    }

    /// Insert a pending follow-up directly into UserDefaults (avoids UNUserNotificationCenter).
    private func insertPending(doseID: UUID, medicationName: String) {
        var pending = DoseFollowUpManager.loadPending()
        pending.append(DoseFollowUpManager.PendingFollowUp(
            doseID: doseID,
            medicationName: medicationName,
            scheduledTime: now.addingTimeInterval(DoseFollowUpManager.followUpDelay)
        ))
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")
    }

    @Test("Pending follow-up is persisted")
    func pendingPersisted() {
        clearPending()
        let doseID = UUID()
        insertPending(doseID: doseID, medicationName: "Clonazepam")

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.count == 1)
        #expect(pending[0].doseID == doseID)
        #expect(pending[0].medicationName == "Clonazepam")

        clearPending()
    }

    @Test("Removing by doseID clears the pending follow-up")
    func removeByDoseID() {
        clearPending()
        let doseID = UUID()
        let otherID = UUID()
        insertPending(doseID: doseID, medicationName: "Clonazepam")
        insertPending(doseID: otherID, medicationName: "Adderall")

        // Manually remove by doseID (same logic as completeFollowUp minus UNNotificationCenter)
        var pending = DoseFollowUpManager.loadPending()
        pending.removeAll { $0.doseID == doseID }
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        let remaining = DoseFollowUpManager.loadPending()
        #expect(remaining.count == 1)
        #expect(remaining[0].doseID == otherID)

        clearPending()
    }

    @Test("pendingFollowUpIfDue returns nil when nothing is scheduled")
    func noPendingReturnsNil() {
        clearPending()
        #expect(DoseFollowUpManager.pendingFollowUpIfDue() == nil)
    }

    @Test("pendingFollowUpIfDue returns nil for future follow-ups")
    func futureFollowUpReturnsNil() {
        clearPending()
        let followUp = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Clonazepam",
            scheduledTime: now.addingTimeInterval(1800)
        )
        let data = try! JSONEncoder().encode([followUp])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        #expect(DoseFollowUpManager.pendingFollowUpIfDue(now: now) == nil)

        clearPending()
    }

    @Test("pendingFollowUpIfDue returns due follow-up")
    func dueFollowUpReturned() {
        clearPending()
        let doseID = UUID()
        let followUp = DoseFollowUpManager.PendingFollowUp(
            doseID: doseID,
            medicationName: "Adderall",
            scheduledTime: now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode([followUp])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        let result = DoseFollowUpManager.pendingFollowUpIfDue(now: now)
        #expect(result != nil)
        #expect(result?.doseID == doseID)

        clearPending()
    }

    @Test("cleanupStale removes old follow-ups")
    func staleCleanup() {
        clearPending()
        let stale = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Old",
            scheduledTime: now.addingTimeInterval(-3 * 3600)
        )
        let recent = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Recent",
            scheduledTime: now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode([stale, recent])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        DoseFollowUpManager.cleanupStale(now: now)

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.count == 1)
        #expect(pending[0].medicationName == "Recent")

        clearPending()
    }

    // MARK: - Decode-failure migration safety (F-086)

    @Test("Nil stored data loads as empty without creating a backup")
    func nilLoadsEmpty() {
        clearPending()
        #expect(DoseFollowUpManager.loadPending().isEmpty)
        // A clean empty state is not a failure — nothing should be backed up.
        #expect(UserDefaults.standard.data(forKey: DoseFollowUpManager.corruptBackupKey) == nil)
    }

    @Test("Corrupt blob loads as empty but is preserved under the backup key")
    func corruptBlobPreserved() {
        clearPending()
        let corrupt = Data("{not valid follow-up json".utf8)
        UserDefaults.standard.set(corrupt, forKey: "pendingDoseFollowUps")

        // Decode fails → returns [] (doesn't crash, doesn't leak stale data)...
        #expect(DoseFollowUpManager.loadPending().isEmpty)
        // ...but the undecodable bytes are preserved, not silently discarded.
        let backup = UserDefaults.standard.data(forKey: DoseFollowUpManager.corruptBackupKey)
        #expect(backup == corrupt)
        // ...and the primary key is cleared so a repeat loadPending doesn't
        // re-hit the decode-failure path and re-log every call (Copilot #164).
        #expect(UserDefaults.standard.data(forKey: "pendingDoseFollowUps") == nil)

        clearPending()
    }

    @Test("A later save does not destroy the preserved corrupt blob")
    func savingDoesNotClobberBackup() {
        clearPending()
        let corrupt = Data("\u{FF}\u{FE} garbage".utf8)
        UserDefaults.standard.set(corrupt, forKey: "pendingDoseFollowUps")

        // First load triggers the backup.
        _ = DoseFollowUpManager.loadPending()
        // Simulate the next savePending overwriting the primary key with [].
        let empty = try! JSONEncoder().encode([DoseFollowUpManager.PendingFollowUp]())
        UserDefaults.standard.set(empty, forKey: "pendingDoseFollowUps")

        // The original corrupt data must still be recoverable from the backup.
        let backup = UserDefaults.standard.data(forKey: DoseFollowUpManager.corruptBackupKey)
        #expect(backup == corrupt)

        clearPending()
    }

    @Test("Notification ID is deterministic for a dose")
    func notificationIDDeterministic() {
        let doseID = UUID()
        let id1 = DoseFollowUpManager.notificationID(for: doseID)
        let id2 = DoseFollowUpManager.notificationID(for: doseID)
        #expect(id1 == id2)
        #expect(id1.contains(doseID.uuidString))
    }
}
