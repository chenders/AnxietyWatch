import Foundation
import Testing

@testable import AnxietyWatch

struct DoseFollowUpManagerTests {

    /// Clear pending follow-ups before each test.
    private func clearPending() {
        UserDefaults.standard.removeObject(forKey: "pendingDoseFollowUps")
    }

    @Test("Schedule adds a pending follow-up")
    func scheduleAddsPending() {
        clearPending()
        let doseID = UUID()
        DoseFollowUpManager.scheduleFollowUp(doseID: doseID, medicationName: "Clonazepam")

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.count == 1)
        #expect(pending[0].doseID == doseID)
        #expect(pending[0].medicationName == "Clonazepam")

        // Cleanup
        DoseFollowUpManager.cancelFollowUp(doseID: doseID)
    }

    @Test("Cancel removes the pending follow-up")
    func cancelRemovesPending() {
        clearPending()
        let doseID = UUID()
        DoseFollowUpManager.scheduleFollowUp(doseID: doseID, medicationName: "Adderall")

        DoseFollowUpManager.cancelFollowUp(doseID: doseID)

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.isEmpty)
    }

    @Test("Complete removes the pending follow-up")
    func completeRemovesPending() {
        clearPending()
        let doseID = UUID()
        DoseFollowUpManager.scheduleFollowUp(doseID: doseID, medicationName: "Clonazepam")

        DoseFollowUpManager.completeFollowUp(doseID: doseID)

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.isEmpty)
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
            scheduledTime: Date.now.addingTimeInterval(1800)
        )
        let data = try! JSONEncoder().encode([followUp])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        #expect(DoseFollowUpManager.pendingFollowUpIfDue() == nil)

        clearPending()
    }

    @Test("pendingFollowUpIfDue returns due follow-up")
    func dueFollowUpReturned() {
        clearPending()
        let doseID = UUID()
        let followUp = DoseFollowUpManager.PendingFollowUp(
            doseID: doseID,
            medicationName: "Adderall",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode([followUp])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        let result = DoseFollowUpManager.pendingFollowUpIfDue()
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
            scheduledTime: Date.now.addingTimeInterval(-3 * 3600)
        )
        let recent = DoseFollowUpManager.PendingFollowUp(
            doseID: UUID(),
            medicationName: "Recent",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode([stale, recent])
        UserDefaults.standard.set(data, forKey: "pendingDoseFollowUps")

        DoseFollowUpManager.cleanupStale()

        let pending = DoseFollowUpManager.loadPending()
        #expect(pending.count == 1)
        #expect(pending[0].medicationName == "Recent")

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
