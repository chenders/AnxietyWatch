import SwiftUI
import SwiftData

struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            albumArtView
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !song.occurrences.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(song.occurrences.count)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    if let last = song.occurrences.map(\.timestamp).max() {
                        Text(last, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var albumArtView: some View {
        SongAlbumArtView(urlString: song.albumArtURL, size: 44)
    }
}
