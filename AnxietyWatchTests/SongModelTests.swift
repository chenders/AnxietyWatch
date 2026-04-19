import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@MainActor
struct SongModelTests {

    @Test("Song initializes with title and artist")
    func songInit() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let song = ModelFactory.song(title: "Everybody Hurts", artist: "R.E.M.")
        context.insert(song)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Song>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Everybody Hurts")
        #expect(fetched.first?.artist == "R.E.M.")
    }

    @Test("SongOccurrence links to Song")
    func occurrenceLinksToSong() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let song = ModelFactory.song()
        context.insert(song)

        let occurrence = ModelFactory.songOccurrence()
        occurrence.song = song
        context.insert(occurrence)
        try context.save()

        #expect(song.occurrences.count == 1)
        #expect(occurrence.song?.id == song.id)
    }

    @Test("SongOccurrence links to AnxietyEntry")
    func occurrenceLinksToEntry() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry(severity: 7)
        context.insert(entry)

        let song = ModelFactory.song()
        context.insert(song)

        let occurrence = ModelFactory.songOccurrence(source: "journal")
        occurrence.song = song
        occurrence.anxietyEntry = entry
        context.insert(occurrence)
        try context.save()

        #expect(occurrence.anxietyEntry?.severity == 7)
        #expect(entry.songOccurrences?.count == 1)
    }

    @Test("Deleting Song cascades to SongOccurrence")
    func deleteSongCascades() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let song = ModelFactory.song()
        context.insert(song)

        let occ = ModelFactory.songOccurrence()
        occ.song = song
        context.insert(occ)
        try context.save()

        context.delete(song)
        try context.save()

        let songs = try context.fetch(FetchDescriptor<Song>())
        let occurrences = try context.fetch(FetchDescriptor<SongOccurrence>())
        #expect(songs.isEmpty)
        #expect(occurrences.isEmpty)
    }

    @Test("Deleting SongOccurrence nullifies AnxietyEntry link")
    func deleteOccurrenceNullifiesEntry() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry()
        context.insert(entry)

        let song = ModelFactory.song()
        context.insert(song)

        let occ = ModelFactory.songOccurrence()
        occ.song = song
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        context.delete(occ)
        try context.save()

        let entries = try context.fetch(FetchDescriptor<AnxietyEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.songOccurrences?.isEmpty != false)
    }
}
