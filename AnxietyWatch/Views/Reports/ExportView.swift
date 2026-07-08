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

                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV Files", systemImage: "tablecells")
                }
            }

            Section("Clinical Report") {
                Button {
                    generatePDF()
                } label: {
                    Label("Generate PDF Report", systemImage: "doc.richtext")
                }

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
        do {
            // Whole selected end day (F-044). DataExporter's range is
            // half-open with an EXCLUSIVE end (`date < end`), so passing the
            // start-of-next-day instant keeps every record of the selected
            // day and excludes the next day's day-keyed rows (which land
            // exactly at that midnight boundary).
            let data = try DataExporter.exportJSON(
                from: modelContext,
                start: ExportDateRange.lowerBound(for: startDate),
                end: ExportDateRange.upperBoundExclusive(for: endDate)
            )
            let url = tempURL("anxietywatch-export.json")
            try data.write(to: url)
            shareItems = [url]
            showingShare = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportCSV() {
        do {
            // Whole selected end day, exclusive-end half-open range (F-044) — see exportJSON.
            let files = try DataExporter.exportCSV(
                from: modelContext,
                start: ExportDateRange.lowerBound(for: startDate),
                end: ExportDateRange.upperBoundExclusive(for: endDate)
            )
            var urls: [URL] = []
            for (filename, data) in files {
                let url = tempURL(filename)
                try data.write(to: url)
                urls.append(url)
            }
            shareItems = urls
            showingShare = true
        } catch {
            errorMessage = error.localizedDescription
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
            end: reportEnd
        )

        let url = tempURL("anxietywatch-report.pdf")
        do {
            try data.write(to: url)
            shareItems = [url]
            showingShare = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func tempURL(_ filename: String) -> URL {
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
