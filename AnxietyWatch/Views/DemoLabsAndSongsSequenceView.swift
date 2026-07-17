#if DEBUG
import SwiftData
import SwiftUI

/// Programmatic recording route: recent fictional labs, then Songs catalog,
/// then a recurring-song detail. It does not inject taps or mouse events.
struct DemoLabsAndSongsSequenceView: View {
    private enum Stage { case labs, songs, detail }
    @Query(sort: \Song.updatedAt, order: .reverse) private var songs: [Song]
    @State private var stage: Stage = .labs

    var body: some View {
        NavigationStack {
            switch stage {
            case .labs:
                LabResultsView()
            case .songs:
                List(songs) { SongRow(song: $0) }
                    .navigationTitle("Songs")
            case .detail:
                if let song = featuredSong {
                    SongDetailView(song: song)
                } else {
                    ContentUnavailableView("No Demo Songs", systemImage: "music.note")
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(6)); stage = .songs
            try? await Task.sleep(for: .seconds(7)); stage = .detail
        }
    }

    private var featuredSong: Song? {
        songs.first { $0.title == "In the Air Tonight" && $0.artist == "Dead When I Found Her" }
            ?? songs.first
    }
}
#endif
