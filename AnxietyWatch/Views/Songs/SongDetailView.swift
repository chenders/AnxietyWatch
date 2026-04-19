import SwiftUI

struct SongDetailView: View {
    let song: Song

    var body: some View {
        Text("Song Detail — \(song.title)")
            .navigationTitle(song.title)
    }
}
