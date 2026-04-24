import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@MainActor
struct SongLinkHelperTests {

    // MARK: - occurrenceSource

    @Test("Journal entries produce 'journal' occurrence source")
    func journalEntrySource() {
        let entry = ModelFactory.anxietyEntry(source: nil)
        #expect(SongLinkHelper.occurrenceSource(for: entry) == "journal")

        let userEntry = ModelFactory.anxietyEntry(source: "user")
        #expect(SongLinkHelper.occurrenceSource(for: userEntry) == "journal")
    }

    @Test("Check-in entries produce 'checkin' occurrence source")
    func checkInEntrySource() {
        let entry = ModelFactory.anxietyEntry(source: "random_checkin")
        #expect(SongLinkHelper.occurrenceSource(for: entry) == "checkin")
    }

    @Test("Dose follow-up entries produce 'journal' occurrence source")
    func doseFollowUpSource() {
        let entry = ModelFactory.anxietyEntry(source: "dose_followup")
        #expect(SongLinkHelper.occurrenceSource(for: entry) == "journal")
    }

    // MARK: - applySongChange: linking

    @Test("Linking a song to an entry creates an occurrence")
    func linkSong() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry(severity: 6)
        let song = ModelFactory.song(title: "Test Song", artist: "Test Artist")
        context.insert(entry)
        context.insert(song)
        try context.save()

        let changed = SongLinkHelper.applySongChange(to: entry, selectedSong: song, in: context)
        try context.save()

        #expect(changed)
        #expect(entry.songOccurrences?.count == 1)
        #expect(entry.songOccurrences?.first?.song?.id == song.id)
        #expect(entry.songOccurrences?.first?.source == "journal")
    }

    @Test("Linking a song to a check-in entry uses 'checkin' source")
    func linkSongToCheckIn() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry(severity: 4, source: "random_checkin")
        let song = ModelFactory.song()
        context.insert(entry)
        context.insert(song)
        try context.save()

        SongLinkHelper.applySongChange(to: entry, selectedSong: song, in: context)
        try context.save()

        #expect(entry.songOccurrences?.first?.source == "checkin")
    }

    // MARK: - applySongChange: unlinking

    @Test("Unlinking a song removes the occurrence")
    func unlinkSong() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry(severity: 5)
        let song = ModelFactory.song()
        context.insert(entry)
        context.insert(song)

        let occ = ModelFactory.songOccurrence(source: "journal")
        occ.song = song
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        let changed = SongLinkHelper.applySongChange(to: entry, selectedSong: nil, in: context)
        try context.save()

        #expect(changed)
        let occurrences = try context.fetch(FetchDescriptor<SongOccurrence>())
        #expect(occurrences.isEmpty)
    }

    @Test("Unlinking updates old song's updatedAt")
    func unlinkUpdatesOldSongTimestamp() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry()
        let song = ModelFactory.song()
        // Set a known past date so we can detect the update
        let pastDate = Date(timeIntervalSince1970: 1_000_000)
        song.updatedAt = pastDate
        context.insert(entry)
        context.insert(song)

        let occ = ModelFactory.songOccurrence()
        occ.song = song
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        SongLinkHelper.applySongChange(to: entry, selectedSong: nil, in: context)
        try context.save()

        #expect(song.updatedAt > pastDate)
    }

    // MARK: - applySongChange: switching

    @Test("Switching songs replaces the occurrence")
    func switchSong() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry(severity: 7)
        let songA = ModelFactory.song(title: "Song A", artist: "Artist A")
        let songB = ModelFactory.song(title: "Song B", artist: "Artist B")
        context.insert(entry)
        context.insert(songA)
        context.insert(songB)

        let occ = ModelFactory.songOccurrence(source: "journal")
        occ.song = songA
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        let changed = SongLinkHelper.applySongChange(to: entry, selectedSong: songB, in: context)
        try context.save()

        #expect(changed)
        #expect(entry.songOccurrences?.count == 1)
        #expect(entry.songOccurrences?.first?.song?.id == songB.id)
    }

    // MARK: - applySongChange: no-op

    @Test("No change when selected song matches current link")
    func noChangeWhenSame() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry()
        let song = ModelFactory.song()
        context.insert(entry)
        context.insert(song)

        let occ = ModelFactory.songOccurrence()
        occ.song = song
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        let changed = SongLinkHelper.applySongChange(to: entry, selectedSong: song, in: context)

        #expect(!changed)
        #expect(entry.songOccurrences?.count == 1)
    }

    @Test("Same song but edited timestamp syncs occurrence")
    func sameSongSyncsTimestamp() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let originalDate = Date(timeIntervalSince1970: 1_000_000)
        let entry = ModelFactory.anxietyEntry(timestamp: originalDate)
        let song = ModelFactory.song()
        context.insert(entry)
        context.insert(song)

        let occ = ModelFactory.songOccurrence(timestamp: originalDate, source: "journal")
        occ.song = song
        occ.anxietyEntry = entry
        context.insert(occ)
        try context.save()

        // Simulate user editing the entry's timestamp
        let newDate = Date(timeIntervalSince1970: 2_000_000)
        entry.timestamp = newDate

        let changed = SongLinkHelper.applySongChange(to: entry, selectedSong: song, in: context)
        try context.save()

        #expect(changed)
        #expect(entry.songOccurrences?.first?.timestamp == newDate)
    }

    @Test("No change when both nil")
    func noChangeWhenBothNil() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let entry = ModelFactory.anxietyEntry()
        context.insert(entry)
        try context.save()

        let changed = SongLinkHelper.applySongChange(to: entry, selectedSong: nil, in: context)

        #expect(!changed)
    }
}
