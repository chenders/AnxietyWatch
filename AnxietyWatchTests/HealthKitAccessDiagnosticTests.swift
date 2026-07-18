import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for the HealthKit access diagnostic — the surface that makes the
/// silent read-authorization freeze visible. The freeze (reduced-pass gate
/// returning "pending", or grants revoked after a bundle-ID / entitlement
/// change) has twice frozen ingestion invisibly (2026-07-13, 2026-07-18).
///
/// The core is a pure state evaluator; the runner composes it over a live
/// `HealthKitDataSource` probe; the history helper distinguishes a revoke
/// from a legitimately-empty store so the banner never cries wolf.
@MainActor
struct HealthKitAccessDiagnosticTests {

    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
    }()

    // MARK: - Pure evaluator (exhaustive truth table + precedence)

    @Test("notRequested wins even when probe data and history are present")
    func notRequestedTakesPrecedence() {
        #expect(evaluateHealthKitAccess(
            needsRequest: true, probeReturnedValue: true, hadRecentHistory: true
        ) == .notRequested)
    }

    @Test("receiving when a probe returned a value and auth is determined")
    func receivingWhenProbePresent() {
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: true, hadRecentHistory: false
        ) == .receiving)
    }

    @Test("likelyRevoked when reads are empty but we had recent data")
    func likelyRevokedWhenEmptyWithHistory() {
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: false, hadRecentHistory: true
        ) == .likelyRevoked)
    }

    @Test("noDataYet when reads are empty and we never had data")
    func noDataYetWhenEmptyNoHistory() {
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: false, hadRecentHistory: false
        ) == .noDataYet)
    }

    // MARK: - Status presentation mapping

    @Test("Status presentation is total, non-empty, and correctly tinted per state")
    func statusPresentationMapping() {
        let allStates: [HealthKitAccessState] = [.receiving, .notRequested, .likelyRevoked, .noDataYet]
        for state in allStates {
            #expect(!state.statusSymbolName.isEmpty)
            #expect(!state.statusTitle.isEmpty)
            #expect(!state.statusDetail.isEmpty)
        }
        #expect(HealthKitAccessState.receiving.statusTint == .positive)
        #expect(HealthKitAccessState.notRequested.statusTint == .warning)
        #expect(HealthKitAccessState.likelyRevoked.statusTint == .warning)
        #expect(HealthKitAccessState.noDataYet.statusTint == .neutral)
    }

    @Test("notRequested and likelyRevoked are visually distinguishable by icon")
    func warningStatesUseDistinctIcons() {
        #expect(HealthKitAccessState.notRequested.statusSymbolName
                != HealthKitAccessState.likelyRevoked.statusSymbolName)
    }

    // MARK: - Dashboard banner scope (approved decision: notRequested only)

    @Test("Dashboard banner fires only for notRequested")
    func bannerScopeIsNotRequestedOnly() {
        #expect(HealthKitAccessState.notRequested.showsDashboardBanner)
        #expect(!HealthKitAccessState.receiving.showsDashboardBanner)
        #expect(!HealthKitAccessState.likelyRevoked.showsDashboardBanner)
        #expect(!HealthKitAccessState.noDataYet.showsDashboardBanner)
    }

    // MARK: - Async runner (probe over HealthKitDataSource)

    @Test("Runner reports notRequested when the auth gate is pending, even with data")
    func runnerNotRequestedDominatesProbe() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(true)
        await mock.setCumulative(.stepCount, value: 5000)  // present, but gate dominates
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: true)
        #expect(result.state == .notRequested)
    }

    @Test("Runner reports receiving when steps are present")
    func runnerReceivingFromSteps() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        await mock.setCumulative(.stepCount, value: 3200)
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: false)
        #expect(result.state == .receiving)
        #expect(result.stepsPresent)
    }

    @Test("Runner reports receiving from resting HR alone")
    func runnerReceivingFromRestingHR() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        await mock.setAverage(.restingHeartRate, value: 58)
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: false)
        #expect(result.state == .receiving)
        #expect(result.restingHRPresent)
    }

    @Test("Runner reports receiving from sleep alone")
    func runnerReceivingFromSleep() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        await mock.setSleep(SleepData(totalMinutes: 400))
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: false)
        #expect(result.state == .receiving)
        #expect(result.sleepPresent)
    }

    @Test("Runner reports likelyRevoked when all probes empty but history exists")
    func runnerLikelyRevoked() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)  // no probe data set → all empty
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: true)
        #expect(result.state == .likelyRevoked)
        #expect(!result.stepsPresent)
        #expect(!result.restingHRPresent)
        #expect(!result.sleepPresent)
    }

    @Test("Runner reports noDataYet when all probes empty and no history")
    func runnerNoDataYet() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: false)
        #expect(result.state == .noDataYet)
    }

    @Test("Runner treats zero steps as absence, not presence")
    func runnerZeroStepsIsAbsence() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        await mock.setCumulative(.stepCount, value: 0)
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: false)
        #expect(!result.stepsPresent)
        #expect(result.state == .noDataYet)
    }

    // MARK: - History helper

    @Test("History true when a recent snapshot has a HealthKit-derived field")
    func historyTrueWithRecentField() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let recent = HealthSnapshot(date: now.addingTimeInterval(-5 * 86_400))
        recent.restingHR = 56
        context.insert(recent)
        try context.save()
        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(HealthKitHistoryProbe.hadRecentHealthKitData(in: snapshots, now: now))
    }

    @Test("History false when recent snapshots have only non-HealthKit fields")
    func historyFalseWhenOnlyCPAP() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let cpapOnly = HealthSnapshot(date: now.addingTimeInterval(-3 * 86_400))
        cpapOnly.cpapAHI = 4.0  // not HealthKit-derived — must not count
        context.insert(cpapOnly)
        try context.save()
        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(!HealthKitHistoryProbe.hadRecentHealthKitData(in: snapshots, now: now))
    }

    @Test("History false when the only HealthKit data is older than the window")
    func historyFalseWhenTooOld() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let old = HealthSnapshot(date: now.addingTimeInterval(-45 * 86_400))
        old.restingHR = 60
        context.insert(old)
        try context.save()
        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(!HealthKitHistoryProbe.hadRecentHealthKitData(in: snapshots, now: now))
    }
}
