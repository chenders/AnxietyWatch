import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CPAPListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CPAPSession.date, order: .reverse) private var sessions: [CPAPSession]
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
                Section("Sessions (\(sessions.count))") {
                    ForEach(sessions) { session in
                        CPAPSessionRow(session: session)
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
        .alert("Import", isPresented: .constant(alertMessage != nil)) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let count = try CPAPImporter.importCSV(from: url, into: modelContext)
                alertMessage = "Imported \(count) session\(count == 1 ? "" : "s")."
            } catch {
                alertMessage = error.localizedDescription
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
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
