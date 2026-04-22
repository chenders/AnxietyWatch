import SwiftData
import SwiftUI

struct JournalEntryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: AnxietyEntry
    @State private var isEditing = false
    @State private var tagText = ""
    @State private var selectedSong: Song?
    @State private var showingSongSearch = false

    @Query(sort: \AnxietyEntry.timestamp, order: .reverse)
    private var recentEntries: [AnxietyEntry]

    /// The song linked to this entry (first occurrence), if any.
    private var linkedSong: Song? {
        entry.songOccurrences?.first?.song
    }

    var body: some View {
        Form {
            Section {
                if isEditing {
                    severityGrid
                } else {
                    HStack {
                        SeverityBadge(severity: entry.severity)
                        Text("\(entry.severity) / 10")
                            .font(.title3)
                    }
                }
            } header: {
                Text(isEditing ? "How are you feeling?" : "Severity")
            } footer: {
                if isEditing {
                    Text(Color.severityLabel(entry.severity))
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.severity(entry.severity))
                }
            }

            Section("Notes") {
                if isEditing {
                    TextEditor(text: $entry.notes)
                        .frame(minHeight: 100)
                } else if entry.notes.isEmpty {
                    Text("No notes")
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.notes)
                }
            }

            if isEditing {
                Section("Tags") {
                    editableTagsView
                }
            } else if !entry.tags.isEmpty {
                Section("Tags") {
                    FlowLayout(spacing: 8) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            if isEditing {
                Section("Song in your head?") {
                    songEditView
                }
            } else if let song = linkedSong {
                Section("Song in your head") {
                    songReadOnlyRow(song)
                }
            }

            Section("Logged") {
                if isEditing {
                    DatePicker("Time", selection: $entry.timestamp)
                } else {
                    Text(entry.timestamp, format: .dateTime)
                }
            }
        }
        .navigationTitle("Entry Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    isEditing.toggle()
                }
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                // Seed the local song selection from the existing link
                selectedSong = linkedSong
            } else {
                applySongChanges()
            }
        }
        .onDisappear {
            if isEditing { applySongChanges() }
        }
        .sheet(isPresented: $showingSongSearch) {
            SongSearchSheet(mode: .picker($selectedSong))
        }
    }

    // MARK: - Severity Grid

    private var severityGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(1...10, id: \.self) { level in
                Button {
                    entry.severity = level
                } label: {
                    Text("\(level)")
                        .font(.title3.bold())
                        .frame(minWidth: 44, minHeight: 44)
                        .background(
                            Circle()
                                .fill(entry.severity == level
                                      ? Color.severity(level)
                                      : Color.severity(level).opacity(0.25))
                        )
                        .foregroundStyle(entry.severity == level ? .white : Color.severity(level))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Severity \(level), \(Color.severityLabel(level))")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tags (Edit Mode)

    /// Most-used tags from recent entries, excluding tags already on this entry.
    private var frequentTags: [String] {
        var counts: [String: Int] = [:]
        for e in recentEntries.prefix(50) {
            for tag in e.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(8)
            .map(\.key)
            .filter { !entry.tags.contains($0) }
    }

    @ViewBuilder
    private var editableTagsView: some View {
        let chips = frequentTags
        if !chips.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(chips, id: \.self) { tag in
                    Button {
                        if !entry.tags.contains(tag) { entry.tags.append(tag) }
                    } label: {
                        Text(tag)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !entry.tags.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(entry.tags, id: \.self) { tag in
                    Button {
                        entry.tags.removeAll { $0 == tag }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tag)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        HStack {
            TextField("Add tag...", text: $tagText)
                .onSubmit { addTag() }
            Button("Add") { addTag() }
                .disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespaces).lowercased()
        if !tag.isEmpty && !entry.tags.contains(tag) {
            entry.tags.append(tag)
        }
        tagText = ""
    }

    // MARK: - Song

    @ViewBuilder
    private var songEditView: some View {
        if let song = selectedSong {
            HStack(spacing: 12) {
                songArtwork(song)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline.bold())
                    Text(song.artist).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedSong = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove linked song")
            }
        } else {
            Button {
                showingSongSearch = true
            } label: {
                Label("Search songs...", systemImage: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func songReadOnlyRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            songArtwork(song)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.subheadline.bold())
                Text(song.artist).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func songArtwork(_ song: Song) -> some View {
        if let urlString = song.albumArtURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "music.note")
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: .rect(cornerRadius: 5))
            }
            .frame(width: 36, height: 36)
            .clipShape(.rect(cornerRadius: 5))
        } else {
            Image(systemName: "music.note")
                .frame(width: 36, height: 36)
                .background(.quaternary, in: .rect(cornerRadius: 5))
        }
    }

    /// Sync the song relationship when exiting edit mode.
    private func applySongChanges() {
        SongLinkHelper.applySongChange(to: entry, selectedSong: selectedSong, in: modelContext)
    }
}
