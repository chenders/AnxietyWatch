import SwiftData
import SwiftUI

struct ExportView: View {
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
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Counts

    private var filteredCounts: (entries: Int, doses: Int, snapshots: Int, cpap: Int) {
        (
            entries: allEntries.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }.count,
            doses: allDoses.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }.count,
            snapshots: allSnapshots.filter { $0.date >= startDate && $0.date <= endDate }.count,
            cpap: allCPAP.filter { $0.date >= startDate && $0.date <= endDate }.count
        )
    }

    // MARK: - Export Actions

    private func exportJSON() {
        do {
            let data = try DataExporter.exportJSON(from: modelContext, start: startDate, end: endDate)
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
            let files = try DataExporter.exportCSV(from: modelContext, start: startDate, end: endDate)
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
        let filteredEntries = allEntries.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
        let filteredDoses = allDoses.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
        let filteredSnapshots = allSnapshots.filter { $0.date >= startDate && $0.date <= endDate }
        let filteredCPAP = allCPAP.filter { $0.date >= startDate && $0.date <= endDate }
        let filteredLabs = allLabResults.filter { $0.effectiveDate >= startDate && $0.effectiveDate <= endDate }

        let data = ReportGenerator.generatePDF(
            entries: filteredEntries,
            doses: filteredDoses,
            definitions: allDefinitions,
            snapshots: filteredSnapshots,
            cpapSessions: filteredCPAP,
            labResults: filteredLabs,
            start: startDate,
            end: endDate
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
