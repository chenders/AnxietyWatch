import SwiftUI
import SwiftData

struct JournalListView: View {
    /// Entries fetched per page. The list starts bounded to this many and grows
    /// on demand rather than materializing the entire (unbounded, multiple-per-
    /// day) AnxietyEntry history at once (F-084).
    static let pageSize = 200

    @State private var showingAddEntry = false
    @State private var selectedSegment = 0
    @State private var journalLimit = JournalListView.pageSize

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
                    JournalEntriesList(limit: journalLimit) {
                        journalLimit += Self.pageSize
                    }
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

}

/// Paginated journal list. Owns a `fetchLimit`-bounded @Query so the primary
/// history isn't fully materialized on every change; when a full page comes
/// back there may be older entries, so it offers a "Load older entries" row
/// that raises the parent's limit (F-084). This preserves full access to the
/// user's history — nothing is silently hidden — while bounding the fetch.
private struct JournalEntriesList: View {
    @Environment(\.modelContext) private var modelContext
    let limit: Int
    let onLoadMore: () -> Void

    @Query private var entries: [AnxietyEntry]

    init(limit: Int, onLoadMore: @escaping () -> Void) {
        self.limit = limit
        self.onLoadMore = onLoadMore
        var descriptor = FetchDescriptor<AnxietyEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        _entries = Query(descriptor)
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink {
                    JournalEntryDetailView(entry: entry).equatable()
                } label: {
                    JournalEntryRow(entry: entry)
                }
            }
            .onDelete(perform: deleteEntries)

            // A full page means the fetch was capped — older entries may exist.
            // (When the total is an exact multiple of the page size this shows
            // once more and then disappears; harmless.)
            if entries.count == limit {
                Button(action: onLoadMore) {
                    Label("Load older entries", systemImage: "clock.arrow.circlepath")
                }
            }
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
        // Snapshot targets before mutating so shifting @Query indices can't
        // delete the wrong row on a multi-offset delete (Copilot review of #165).
        let toDelete = offsets.map { entries[$0] }
        for entry in toDelete {
            modelContext.delete(entry)
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
        .severity(severity)
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    JournalListView()
        .modelContainer(container)
}
#endif
