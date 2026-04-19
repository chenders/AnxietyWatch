import SwiftUI
import SwiftData

struct SongDetailView: View {
    @Bindable var song: Song
    @Environment(\.modelContext) private var modelContext
    @State private var isEditing = false

    var body: some View {
        List {
            // Header
            Section {
                HStack(spacing: 16) {
                    albumArt
                    VStack(alignment: .leading, spacing: 4) {
                        if isEditing {
                            TextField("Title", text: $song.title)
                                .font(.headline)
                            TextField("Artist", text: $song.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(song.title)
                                .font(.headline)
                            Text(song.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if isEditing {
                            TextField("Album", text: Binding(
                                get: { song.album ?? "" },
                                set: { song.album = $0.isEmpty ? nil : $0 }
                            ))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        } else if let album = song.album, !album.isEmpty {
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Occurrence count
            Section {
                LabeledContent("Times logged", value: "\(song.occurrences.count)")
                if let first = song.occurrences.map(\.timestamp).min() {
                    LabeledContent("First logged", value: first.formatted(.dateTime.month().day().year()))
                }
                if let last = song.occurrences.map(\.timestamp).max() {
                    LabeledContent("Last logged", value: last.formatted(.relative(presentation: .named)))
                }
            }

            // Lyrics
            Section("Lyrics") {
                if isEditing {
                    TextEditor(text: Binding(
                        get: { song.lyrics ?? "" },
                        set: { song.lyrics = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 200)
                    .font(.body.monospaced())
                } else if let lyrics = song.lyrics, !lyrics.isEmpty {
                    Text(lyrics)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    Text("No lyrics available")
                        .foregroundStyle(.secondary)
                }
            }

            // Occurrence history
            if !song.occurrences.isEmpty {
                Section("Occurrence History") {
                    ForEach(song.occurrences.sorted(by: { $0.timestamp > $1.timestamp })) { occ in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(occ.timestamp, format: .dateTime.month().day().hour().minute())
                                    .font(.subheadline)
                                if let source = occ.source {
                                    Text(source)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if let entry = occ.anxietyEntry {
                                SeverityBadge(severity: entry.severity)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(song.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing {
                        song.lyricsSource = song.lyrics != nil ? "manual" : nil
                        song.updatedAt = Date()
                    }
                    isEditing.toggle()
                }
            }
        }
    }

    private var albumArt: some View {
        Group {
            if let urlString = song.albumArtURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, height: 80)
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                }
            } else {
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, height: 80)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(.rect(cornerRadius: 8))
    }
}
