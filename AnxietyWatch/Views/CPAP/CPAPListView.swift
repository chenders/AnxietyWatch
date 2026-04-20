import os
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CPAPListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CPAPSession.date, order: .reverse) private var sessions: [CPAPSession]
    @Query(sort: \HealthSnapshot.date, order: .reverse) private var snapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp, order: .reverse) private var entries: [AnxietyEntry]
    @State private var showingAddSession = false
    @State private var showingImporter = false
    @State private var alertMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    showingAddSession = true
                } label: {
                    Label("Add Manual Entry", systemImage: "plus.circle")
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import CSV File", systemImage: "doc.badge.plus")
                }
            }

            if sessions.isEmpty {
                Section {
                    Text("No CPAP sessions recorded yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                summarySection

                Section("Sessions (\(sessions.count))") {
                    ForEach(sessions) { session in
                        NavigationLink {
                            CPAPDetailView(session: session, snapshots: snapshots, entries: entries)
                        } label: {
                            CPAPSessionRow(session: session)
                        }
                    }
                    .onDelete(perform: deleteSessions)
                }
            }
        }
        .navigationTitle("CPAP Data")
        .sheet(isPresented: $showingAddSession) {
            AddCPAPSessionView()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Import", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        let now = Date.now
        let last7 = sessions.filter {
            $0.date >= Calendar.current.date(byAdding: .day, value: -7, to: now)!
        }
        let last30 = sessions.filter {
            $0.date >= Calendar.current.date(byAdding: .day, value: -30, to: now)!
        }

        Section("Summary") {
            if !last7.isEmpty {
                let avg7 = last7.map(\.ahi).reduce(0, +) / Double(last7.count)
                LabeledContent("7-day avg AHI", value: String(format: "%.1f", avg7))
            }
            if !last30.isEmpty {
                let avg30 = last30.map(\.ahi).reduce(0, +) / Double(last30.count)
                LabeledContent("30-day avg AHI", value: String(format: "%.1f", avg30))
            }
            LabeledContent("Total sessions", value: "\(sessions.count)")
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let result = try CPAPImporter.importCSV(from: url, into: modelContext)
                if result.updated == 0 {
                    alertMessage = "Imported \(result.inserted) session\(result.inserted == 1 ? "" : "s")."
                } else if result.inserted == 0 {
                    alertMessage = "Updated \(result.updated) session\(result.updated == 1 ? "" : "s")."
                } else {
                    alertMessage = "Imported \(result.inserted) new, updated \(result.updated) existing (\(result.total) total)."
                }
                // Backfill snapshots for imported date range
                if let dateRange = result.dateRange {
                    Task { @MainActor in
                        await backfillSnapshots(dateRange: dateRange)
                    }
                }
            } catch {
                alertMessage = error.localizedDescription
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func backfillSnapshots(dateRange: ClosedRange<Date>) async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        var date = dateRange.lowerBound
        while date <= dateRange.upperBound {
            do {
                try await aggregator.aggregateDay(date)
            } catch {
                Log.data.error("Backfill snapshot failed for \(date.formatted(.dateTime.month().day()), privacy: .public): \(error, privacy: .public)")
            }
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? dateRange.upperBound.addingTimeInterval(1)
        }
    }

    private func deleteSessions(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
    }
}

// MARK: - Row

struct CPAPSessionRow: View {
    let session: CPAPSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.date, format: .dateTime.month().day().year())
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "AHI %.1f", session.ahi))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(ahiColor)
            }
            HStack(spacing: 12) {
                Label(usageString, systemImage: "clock")
                if let leak = session.leakRate95th {
                    Label(String(format: "%.1f L/min leak", leak), systemImage: "wind")
                }
                Label(session.importSource, systemImage: "arrow.down.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var usageString: String {
        let h = session.totalUsageMinutes / 60
        let m = session.totalUsageMinutes % 60
        return "\(h)h \(m)m"
    }

    /// AHI clinical severity: <5 normal, 5-15 mild, 15-30 moderate, >30 severe
    private var ahiColor: Color {
        switch session.ahi {
        case ..<5: return .green
        case 5..<15: return .yellow
        case 15..<30: return .orange
        default: return .red
        }
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        CPAPListView()
    }
    .modelContainer(container)
}
#endif
