import SwiftUI
import SwiftData

/// Mode determines behavior after song selection.
enum SongSearchMode {
    /// Browsing catalog — adds to catalog
    case catalog
    /// Picking for journal/check-in — returns the selected song
    case picker(Binding<Song?>)
}

struct SongSearchSheet: View {
    let mode: SongSearchMode
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var localSongs: [Song]

    @State private var query = ""
    @State private var searchResults: [SongService.SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !filteredLocalSongs.isEmpty {
                    Section("Your Songs") {
                        ForEach(filteredLocalSongs) { song in
                            Button {
                                selectLocalSong(song)
                            } label: {
                                localSongLabel(song)
                            }
                            .tint(.primary)
                        }
                    }
                }

                if !searchResults.isEmpty {
                    Section("From Genius") {
                        ForEach(searchResults) { result in
                            Button {
                                addGeniusResult(result)
                            } label: {
                                geniusResultLabel(result)
                            }
                            .tint(.primary)
                        }
                    }
                }

                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .searchable(text: $query, prompt: "Search for a song...")
            .onChange(of: query) { _, newValue in
                debounceSearch(newValue)
            }
            .navigationTitle("Search Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Local filtering

    private var filteredLocalSongs: [Song] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return localSongs.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    // MARK: - Search

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        searchResults = []
        errorMessage = nil

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    @MainActor
    private func performSearch(_ text: String) async {
        isSearching = true
        defer { isSearching = false }

        do {
            let results = try await SongService.search(query: text)
            // Filter out songs already in local catalog
            let localGeniusIds = Set(localSongs.compactMap(\.geniusId))
            searchResults = results.filter { !localGeniusIds.contains($0.geniusId) }
        } catch is CancellationError {
            // Ignore cancellation
        } catch {
            errorMessage = "Search failed. Check server connection."
        }
    }

    // MARK: - Selection

    private func selectLocalSong(_ song: Song) {
        switch mode {
        case .catalog:
            dismiss()
        case .picker(let binding):
            binding.wrappedValue = song
            dismiss()
        }
    }

    private func addGeniusResult(_ result: SongService.SearchResult) {
        Task {
            do {
                let serverSong = try await SongService.addByGeniusId(result.geniusId)
                let song = try SongService.upsertLocal(from: serverSong, in: modelContext)
                try modelContext.save()

                switch mode {
                case .catalog:
                    dismiss()
                case .picker(let binding):
                    binding.wrappedValue = song
                    dismiss()
                }
            } catch {
                errorMessage = "Failed to add song."
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func localSongLabel(_ song: Song) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            SongRow(song: song)
        }
    }

    @ViewBuilder
    private func geniusResultLabel(_ result: SongService.SearchResult) -> some View {
        HStack(spacing: 12) {
            geniusResultArt(result)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(result.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "plus.circle")
                .foregroundStyle(Color.accentColor)
        }
    }

    private func geniusResultArt(_ result: SongService.SearchResult) -> some View {
        Group {
            if let urlString = result.albumArtUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.rect(cornerRadius: 5))
    }
}
