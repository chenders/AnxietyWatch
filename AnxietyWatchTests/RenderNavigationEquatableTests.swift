import Foundation
import SwiftData
import Testing
@testable import AnxietyWatch

/// Regression coverage for Phase 2 findings F-001–F-005, F-032, F-073: the
/// closure-based `NavigationLink` destinations that own a `@Query` must conform
/// to `Equatable` on identity props only, so the paired `.equatable()` at the
/// call site lets SwiftUI dedupe the destination across parent re-renders. Without
/// it, iOS 26 restarts the NavigationStack push every render → ~30 Hz loop →
/// `CA::Layer::layout_is_active` use-after-free. See CLAUDE.md render-pitfall #2.
///
/// The build already enforces that each destination is `Equatable` (`.equatable()`
/// fails to compile otherwise); these tests lock in the `==` *semantics* so a
/// future edit can't silently widen or break identity comparison.
@MainActor
struct RenderNavigationEquatableTests {

    // Destinations with no identity inputs (all state is @Query/@State) are
    // trivially equal, so every rebuild dedupes. Guards F-003, F-005, F-032, F-073.
    @Test func trivialQueryDestinationsAreAlwaysEqual() {
        #expect(CorrelationInsightsView() == CorrelationInsightsView())
        #expect(CPAPListView() == CPAPListView())
        #expect(PrescriptionListView() == PrescriptionListView())
        #expect(PharmacyListView() == PharmacyListView())
        #expect(ExportView() == ExportView())
    }

    // LabResultsView is itself a trivially-equal destination (F-073 call site).
    @Test func labResultsViewIsTriviallyEqual() {
        #expect(LabResultsView() == LabResultsView())
    }

    // F-001: LabTestHistoryView equality keys on `loincCode` only, not on the
    // @Query results it also holds.
    @Test func labTestHistoryEquatesOnLoincCode() throws {
        let defs = LabTestRegistry.TestCategory.allCases
            .flatMap { LabTestRegistry.definitions(in: $0) }
        let a = try #require(defs.first)
        let b = try #require(defs.first { $0.loincCode != a.loincCode })
        #expect(
            LabTestHistoryView(loincCode: a.loincCode, definition: a)
            == LabTestHistoryView(loincCode: a.loincCode, definition: a)
        )
        #expect(
            LabTestHistoryView(loincCode: a.loincCode, definition: a)
            != LabTestHistoryView(loincCode: b.loincCode, definition: b)
        )
        // Same loincCode but a DIFFERENT `definition` must still be equal —
        // proves `==` keys on loincCode ONLY. A regression that folded
        // `definition` into `==` would fail this assertion.
        #expect(
            LabTestHistoryView(loincCode: a.loincCode, definition: a)
            == LabTestHistoryView(loincCode: a.loincCode, definition: b)
        )
    }

    // F-004: JournalEntryDetailView equality keys on the entry's stable
    // persistentModelID, not on its @Query/@State.
    @Test func journalEntryDetailEquatesOnEntryIdentity() throws {
        let container = try TestHelpers.makeFullContainer()
        let ctx = container.mainContext
        let e1 = AnxietyEntry(timestamp: Date(timeIntervalSince1970: 1_000_000), severity: 5)
        let e2 = AnxietyEntry(timestamp: Date(timeIntervalSince1970: 2_000_000), severity: 7)
        ctx.insert(e1)
        ctx.insert(e2)
        #expect(JournalEntryDetailView(entry: e1) == JournalEntryDetailView(entry: e1))
        #expect(JournalEntryDetailView(entry: e1) != JournalEntryDetailView(entry: e2))
    }

    // F-002: CorrelationChartView equality keys on the correlation's stable
    // persistentModelID, not on its two @Query properties.
    @Test func correlationChartEquatesOnModelIdentity() throws {
        let container = try TestHelpers.makeFullContainer()
        let ctx = container.mainContext
        let c1 = PhysiologicalCorrelation(signalName: "hrv_avg", correlation: -0.4, pValue: 0.01, sampleCount: 30)
        let c2 = PhysiologicalCorrelation(signalName: "resting_hr", correlation: 0.3, pValue: 0.04, sampleCount: 28)
        ctx.insert(c1)
        ctx.insert(c2)
        #expect(CorrelationChartView(correlation: c1) == CorrelationChartView(correlation: c1))
        #expect(CorrelationChartView(correlation: c1) != CorrelationChartView(correlation: c2))
    }
}
