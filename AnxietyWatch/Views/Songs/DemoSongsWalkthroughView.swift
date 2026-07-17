#if DEBUG
import SwiftData
import SwiftUI

/// Deterministic, read-only route for recording the fictional Songs feature.
struct DemoSongsWalkthroughView: View {
    @Query(sort: \Song.updatedAt, order: .reverse) private var songs: [Song]
    @State private var selectedSong: Song?

    var body: some View {
        NavigationStack {
            List(songs) { song in
                Button { selectedSong = song } label: { SongRow(song: song) }
                    .buttonStyle(.plain)
            }
            .navigationTitle("Songs")
            .overlay {
                if songs.isEmpty {
                    ContentUnavailableView("No Demo Songs", systemImage: "music.note")
                }
            }
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-demoAutoOpenSong") else { return }
                try? await Task.sleep(for: .seconds(4))
                selectedSong = songs.first {
                    $0.title == "In the Air Tonight" && $0.artist == "Dead When I Found Her"
                } ?? songs.first
            }
            .navigationDestination(item: $selectedSong) { song in
                SongDetailView(song: song)
            }
        }
    }
}
#endif
