import SwiftData
import SwiftUI

/// Effective query range for the date-only export picker.
///
/// The `From`/`To` `DatePicker`s display calendar days only, but their bound
/// `Date` values carry the time-of-day that was current when the sheet opened
/// (both seeded from `.now`). Filtering directly against those raw instants
/// silently drops same-day records logged after the sheet opened — e.g. an
/// anxiety entry at 8 PM when the sheet was opened at 10 AM (F-044). We
/// normalize to whole calendar days: the lower bound is the start of the
/// selected start day, and the upper bound is the start of the day *after* the
/// selected end day, treated as exclusive (`timestamp < upperBoundExclusive`)
/// so the entire end day — including its late records — is in range.
///
/// This is the "padded vs unpadded" pitfall inverted: the query bound must be
/// end-of-day, never the raw picked instant.
enum ExportDateRange {
    /// Inclusive lower bound: start of the selected start day.
    static func lowerBound(for start: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: start)
    }

    /// Exclusive upper bound: start of the day after the selected end day.
    /// A record is in range iff `timestamp >= lowerBound && timestamp < upperBoundExclusive`.
    static func upperBoundExclusive(for end: Date, calendar: Calendar = .current) -> Date {
        // Start of the day AFTER the selected end day. Both the primary and
        // fallback paths are Calendar-based (DST-safe): `dateInterval(of:.day)`
        // gives this day's [start, nextStart) so `.end` IS the next midnight,
        // and `date(byAdding:.day, 1)` is the same instant computed the other
        // way. Neither uses fixed 24h arithmetic, which would land at 01:00 on
        // a spring-forward day (Copilot review of #164). Never falls back to
        // the raw picked instant, which would reintroduce the same-day-drop.
        //
        // The last-ditch `+86_400s` runs only if BOTH Calendar paths return
        // nil (not reachable with the Gregorian calendar). It uses fixed 24h
        // arithmetic — so on a DST boundary it could land at 23:00 or 01:00
        // rather than exactly midnight — but that still ADVANCES past the end
        // day, which is the function's contract. Returning startOfEndDay here
        // would collapse the range and silently drop the entire selected end
        // day; a one-hour skew on an already-impossible branch is the far
        // better failure mode (Copilot review of #164, round 6).
        let startOfEndDay = calendar.startOfDay(for: end)
        return calendar.dateInterval(of: .day, for: startOfEndDay)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: startOfEndDay)
            ?? startOfEndDay.addingTimeInterval(24 * 60 * 60)
    }
}

struct ExportView: View, Equatable {
    @Environment(\.modelContext) private var modelContext
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    @State private var endDate = Date.now
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var errorMessage: String?
    // Serializes the now-async JSON/CSV exports: a rapid double-tap could
    // otherwise spawn two concurrent background exports racing on shareItems.
    @State private var isExporting = false

    @Query(sort: \AnxietyEntry.timestamp) private var allEntries: [AnxietyEntry]
    @Query(sort: \MedicationDose.timestamp) private var allDoses: [MedicationDose]
    @Query private var allDefinitions: [MedicationDefinition]
    @Query(sort: \HealthSnapshot.date) private var allSnapshots: [HealthSnapshot]
    @Query(sort: \CPAPSession.date) private var allCPAP: [CPAPSession]
    @Query(sort: \ClinicalLabResult.effectiveDate) private var allLabResults: [ClinicalLabResult]

    // Trivially Equatable (no identity inputs — all state is @Query/@State);
    // paired with `.equatable()` at the NavigationLink call site so SwiftUI
    // dedupes rebuilds. See CLAUDE.md render-pitfall #2.
    static func == (lhs: ExportView, rhs: ExportView) -> Bool { true }

    var body: some View {
        Form {
            Section("Date Range") {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("To", selection: $endDate, displayedComponents: .date)
            }

            Section("Export Data") {
                Button {
                    exportJSON()
                } label: {
                    Label("Export JSON", systemImage: "doc.text")
                }
                .disabled(isExporting)

                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV Files", systemImage: "tablecells")
                }
                .disabled(isExporting)
            }

            Section("Clinical Report") {
                Button {
                    generatePDF()
                } label: {
                    Label("Generate PDF Report", systemImage: "doc.richtext")
                }
                // Disabled during an in-flight JSON/CSV export so it can't
                // overwrite the shared shareItems/showingShare payload mid-race
                // (Copilot review of #167).
                .disabled(isExporting)

                Text("Formatted summary suitable for sharing with your clinician.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data Summary") {
                let filtered = filteredCounts
                LabeledContent("Anxiety entries", value: "\(filtered.entries)")
                LabeledContent("Medication doses", value: "\(filtered.doses)")
                LabeledContent("Health snapshots", value: "\(filtered.snapshots)")
                LabeledContent("CPAP sessions", value: "\(filtered.cpap)")
            }
        }
        .navigationTitle("Export & Reports")
        .sheet(isPresented: $showingShare) {
            ShareSheet(items: shareItems)
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Counts

    private var filteredCounts: (entries: Int, doses: Int, snapshots: Int, cpap: Int) {
        let lower = ExportDateRange.lowerBound(for: startDate)
        let upper = ExportDateRange.upperBoundExclusive(for: endDate)
        return (
            entries: allEntries.filter { $0.timestamp >= lower && $0.timestamp < upper }.count,
            doses: allDoses.filter { $0.timestamp >= lower && $0.timestamp < upper }.count,
            snapshots: allSnapshots.filter { $0.date >= lower && $0.date < upper }.count,
            cpap: allCPAP.filter { $0.date >= lower && $0.date < upper }.count
        )
    }

    // MARK: - Export Actions

    private func exportJSON() {
        // Whole selected end day (F-044). DataExporter's range is half-open
        // with an EXCLUSIVE end (`date < end`), so passing the start-of-next-
        // day instant keeps every record of the selected day and excludes the
        // next day's day-keyed rows (which land exactly at that boundary).
        guard !isExporting else { return }
        isExporting = true
        let start = ExportDateRange.lowerBound(for: startDate)
        let end = ExportDateRange.upperBoundExclusive(for: endDate)
        // Fetch + encode on a background context (fresh ModelContext off the
        // container) so the export doesn't block the main actor (F-056); the
        // encoded Data is Sendable, so only view-state updates return to main.
        let container = modelContext.container
        Task { @MainActor in
            defer { isExporting = false }
            do {
                // Flush pending inserts before exporting on a SEPARATE context.
                // The app relies on SwiftData autosave, and @Query reflects
                // not-yet-saved inserts in the SHARED context — but a fresh
                // ModelContext(container) only sees the persisted store, so a
                // record logged moments earlier could be silently omitted from
                // the export without this save (medical review of #167).
                try modelContext.save()
                // Fetch, encode, AND write the file all inside the detached
                // task — the JSON Data can be large, so writing it on the main
                // actor would reintroduce the stall this offload removes
                // (Copilot review of #167). Only the Sendable URL returns.
                let url = try await Task.detached(priority: .userInitiated) {
                    let data = try DataExporter.exportJSON(from: ModelContext(container), start: start, end: end)
                    let url = Self.tempURL("anxietywatch-export.json")
                    try data.write(to: url)
                    return url
                }.value
                shareItems = [url]
                showingShare = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportCSV() {
        // Whole selected end day, exclusive-end half-open range (F-044) — see exportJSON.
        guard !isExporting else { return }
        isExporting = true
        let start = ExportDateRange.lowerBound(for: startDate)
        let end = ExportDateRange.upperBoundExclusive(for: endDate)
        let container = modelContext.container
        Task { @MainActor in
            defer { isExporting = false }
            do {
                // Flush pending inserts first — see exportJSON (medical review
                // of #167): a fresh background ModelContext only sees the
                // persisted store.
                try modelContext.save()
                // Background fetch + CSV encode + file writes (F-056); large
                // exports would otherwise block the main actor on each
                // data.write (Copilot review of #167). Only the Sendable [URL]
                // returns to the main actor.
                let urls = try await Task.detached(priority: .userInitiated) { () -> [URL] in
                    let files = try DataExporter.exportCSV(from: ModelContext(container), start: start, end: end)
                    var urls: [URL] = []
                    for (filename, data) in files {
                        let url = Self.tempURL(filename)
                        try data.write(to: url)
                        urls.append(url)
                    }
                    return urls
                }.value
                shareItems = urls
                showingShare = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func generatePDF() {
        // Filter to the whole selected day range (F-044); the raw picked
        // instants would drop same-day late records.
        let lower = ExportDateRange.lowerBound(for: startDate)
        let upper = ExportDateRange.upperBoundExclusive(for: endDate)
        let filteredEntries = allEntries.filter { $0.timestamp >= lower && $0.timestamp < upper }
        let filteredDoses = allDoses.filter { $0.timestamp >= lower && $0.timestamp < upper }
        let filteredSnapshots = allSnapshots.filter { $0.date >= lower && $0.date < upper }
        let filteredCPAP = allCPAP.filter { $0.date >= lower && $0.date < upper }
        let filteredLabs = allLabResults.filter { $0.effectiveDate >= lower && $0.effectiveDate < upper }

        // Hand ReportGenerator DAY-ALIGNED bounds so its per-day rate math
        // (dateComponents(.day, from:to:)) and HRV status anchor operate on
        // the same window the data was filtered to — passing the raw picked
        // instants (with the sheet-open time-of-day) computed against a
        // different window than the filtered arrays (Copilot review of #164).
        let reportStart = lower
        let reportEnd = Calendar.current.startOfDay(for: endDate)

        let data = ReportGenerator.generatePDF(
            entries: filteredEntries,
            doses: filteredDoses,
            definitions: allDefinitions,
            snapshots: filteredSnapshots,
            cpapSessions: filteredCPAP,
            labResults: filteredLabs,
            start: reportStart,
            end: reportEnd,
            // Unfiltered history for the HRV 30-day baseline so a report range
            // shorter than 30 days doesn't compute a mislabeled "30-day"
            // baseline from only the range's data (F-095).
            baselineSnapshots: allSnapshots
        )

        let url = Self.tempURL("anxietywatch-report.pdf")
        do {
            try data.write(to: url)
            shareItems = [url]
            showingShare = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // nonisolated static so it can be called from inside the detached export
    // tasks (which write files off the main actor) as well as from generatePDF.
    private nonisolated static func tempURL(_ filename: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        ExportView()
    }
    .modelContainer(container)
}
#endif
