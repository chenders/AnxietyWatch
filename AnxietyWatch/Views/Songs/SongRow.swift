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
        Group {
            if let urlString = song.albumArtURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    musicNotePlaceholder
                }
            } else {
                musicNotePlaceholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: 6))
    }

    private var musicNotePlaceholder: some View {
        Image(systemName: "music.note")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .background(.quaternary, in: .rect(cornerRadius: 6))
    }
}
