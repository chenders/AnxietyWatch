import SwiftUI
import SwiftData

struct JournalListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnxietyEntry.timestamp, order: .reverse)
    private var entries: [AnxietyEntry]
    @State private var showingAddEntry = false
    @State private var selectedSegment = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedSegment) {
                    Text("Journal").tag(0)
                    Text("Songs").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedSegment == 0 {
                    journalList
                } else {
                    SongCatalogView()
                }
            }
            .navigationTitle(selectedSegment == 0 ? "Journal" : "Songs")
            .toolbar {
                if selectedSegment == 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddEntry = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddEntry) {
                AddJournalEntryView()
            }
        }
    }

    private var journalList: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink {
                    JournalEntryDetailView(entry: entry)
                } label: {
                    JournalEntryRow(entry: entry)
                }
            }
            .onDelete(perform: deleteEntries)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Entries Yet",
                    systemImage: "book",
                    description: Text("Tap + to log your first anxiety entry")
                )
            }
        }
    }

    private func deleteEntries(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(entries[index])
        }
    }
}

// MARK: - Row

struct JournalEntryRow: View {
    let entry: AnxietyEntry

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: entry.severity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline.bold())
                    if entry.source == "random_checkin" {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Severity Badge

struct SeverityBadge: View {
    let severity: Int

    var body: some View {
        Text("\(severity)")
            .font(.headline.bold())
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color, in: .circle)
    }

    private var color: Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    JournalListView()
        .modelContainer(container)
}
#endif
