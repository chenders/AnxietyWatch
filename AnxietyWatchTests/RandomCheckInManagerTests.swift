import Foundation
import Testing

@testable import AnxietyWatch

@Suite(.serialized)
struct RandomCheckInManagerTests {

    private func clearState() {
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_pending")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_enabled")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_frequencyPerDay")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_quietHoursStart")
        UserDefaults.standard.removeObject(forKey: "randomCheckIn_quietHoursEnd")
    }

    @Test("Default frequency is 2")
    func defaultFrequency() {
        clearState()
        #expect(RandomCheckInManager.frequencyPerDay == 2)
    }

    @Test("Default quiet hours are 22-8")
    func defaultQuietHours() {
        clearState()
        #expect(RandomCheckInManager.quietHoursStart == 22)
        #expect(RandomCheckInManager.quietHoursEnd == 8)
    }

    @Test("Default is disabled")
    func defaultDisabled() {
        clearState()
        #expect(RandomCheckInManager.isEnabled == false)
    }

    @Test("Pending check-in round-trips through UserDefaults")
    func pendingPersistence() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")

        let loaded = RandomCheckInManager.loadPending()
        #expect(loaded != nil)
        #expect(loaded?.notificationId == "test-id")
        clearState()
    }

    @Test("loadPending returns nil when no pending check-in")
    func noPending() {
        clearState()
        #expect(RandomCheckInManager.loadPending() == nil)
    }

    @Test("pendingCheckInIfDue returns false when nothing pending")
    func noPendingNotDue() {
        clearState()
        #expect(RandomCheckInManager.pendingCheckInIfDue() == false)
    }

    @Test("pendingCheckInIfDue returns false for future check-in")
    func futurePendingNotDue() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(3600)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")
        #expect(RandomCheckInManager.pendingCheckInIfDue() == false)
        clearState()
    }

    @Test("pendingCheckInIfDue returns true for past check-in within 24h")
    func pastPendingIsDue() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")
        #expect(RandomCheckInManager.pendingCheckInIfDue() == true)
        clearState()
    }

    @Test("pendingCheckInIfDue returns false for stale check-in (>24h)")
    func stalePendingNotDue() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-25 * 3600)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")
        #expect(RandomCheckInManager.pendingCheckInIfDue() == false)
        clearState()
    }

    @Test("cleanupStale removes stale check-in")
    func staleCleanup() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-25 * 3600)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")
        RandomCheckInManager.cleanupStale()
        #expect(RandomCheckInManager.loadPending() == nil)
        clearState()
    }

    @Test("cleanupStale keeps recent check-in")
    func recentNotCleaned() {
        clearState()
        let pending = RandomCheckInManager.PendingCheckIn(
            notificationId: "test-id",
            scheduledTime: Date.now.addingTimeInterval(-300)
        )
        let data = try! JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: "randomCheckIn_pending")
        RandomCheckInManager.cleanupStale()
        #expect(RandomCheckInManager.loadPending() != nil)
        clearState()
    }

    @Test("nextRandomTime returns a time within waking hours")
    func randomTimeInWakingHours() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
        let target = RandomCheckInManager.nextRandomTime(
            from: now, frequency: 2, quietStart: 22, quietEnd: 8
        )
        let hour = calendar.component(.hour, from: target)
        #expect(hour >= 8 && hour < 22, "Target hour \(hour) should be in waking window")
    }

    @Test("nextRandomTime after all slots returns tomorrow")
    func allSlotsPassed() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23))!
        let target = RandomCheckInManager.nextRandomTime(
            from: now, frequency: 2, quietStart: 22, quietEnd: 8
        )
        let dayComponent = calendar.component(.day, from: target)
        #expect(dayComponent == 16, "Should schedule for next day")
        let hour = calendar.component(.hour, from: target)
        #expect(hour >= 8 && hour < 15, "Should be in first slot (8-15)")
    }

    @Test("nextRandomTime is always in the future")
    func randomTimeInFuture() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        for _ in 0..<20 {
            let target = RandomCheckInManager.nextRandomTime(
                from: now, frequency: 2, quietStart: 22, quietEnd: 8
            )
            #expect(target > now, "Target should be after now")
        }
    }

    @Test("nextRandomTime with frequency 4 stays in waking window")
    func highFrequencyInWindow() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8))!
        for _ in 0..<20 {
            let target = RandomCheckInManager.nextRandomTime(
                from: now, frequency: 4, quietStart: 22, quietEnd: 8
            )
            let hour = calendar.component(.hour, from: target)
            #expect(hour >= 8 && hour < 22, "Target hour \(hour) should be in waking window")
        }
    }

    @Test("nextRandomTime at last minute of slot does not crash")
    func lastMinuteOfSlot() {
        let calendar = Calendar.current
        // Frequency 2, quiet 22-8: slot 1 is 480-900 (8:00-15:00)
        // Set now to 14:59 (minute 899) — effectiveStart would be 900 == slotEnd
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 14, minute: 59))!
        let target = RandomCheckInManager.nextRandomTime(
            from: now, frequency: 2, quietStart: 22, quietEnd: 8
        )
        // Should skip to slot 2 (15:00-22:00) or tomorrow, not crash
        #expect(target > now, "Should not crash and should be in the future")
        let hour = calendar.component(.hour, from: target)
        #expect(hour >= 15 || hour < 8, "Should be in slot 2 or tomorrow's slot 1")
    }
}
