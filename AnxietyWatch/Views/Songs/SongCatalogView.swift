import SwiftUI
import SwiftData

struct SongCatalogView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.updatedAt, order: .reverse)
    private var songs: [Song]
    @State private var showingSearch = false

    var body: some View {
        List {
            ForEach(sortedSongs) { song in
                NavigationLink {
                    SongDetailView(song: song)
                } label: {
                    SongRow(song: song)
                }
            }
            .onDelete(perform: deleteSongs)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSearch = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingSearch) {
            SongSearchSheet(mode: .catalog)
        }
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView(
                    "No Songs Yet",
                    systemImage: "music.note",
                    description: Text("Tap + to search and add a song")
                )
            }
        }
    }

    /// Songs sorted by most recent occurrence, then by title.
    private var sortedSongs: [Song] {
        songs.sorted { a, b in
            let aLast = a.occurrences.map(\.timestamp).max() ?? .distantPast
            let bLast = b.occurrences.map(\.timestamp).max() ?? .distantPast
            if aLast != bLast { return aLast > bLast }
            return a.title < b.title
        }
    }

    private func deleteSongs(offsets: IndexSet) {
        let sorted = sortedSongs
        for index in offsets {
            modelContext.delete(sorted[index])
        }
    }
}
