import Foundation
import SwiftData

/// Manages linking/unlinking songs to anxiety entries via SongOccurrence.
enum SongLinkHelper {

    /// Derives the SongOccurrence source from the entry's source.
    static func occurrenceSource(for entry: AnxietyEntry) -> String {
        entry.source == "random_checkin" ? "checkin" : "journal"
    }

    /// Updates the song linked to an entry, replacing existing occurrences if different.
    /// - Returns: `true` if any changes were made.
    @discardableResult
    static func applySongChange(
        to entry: AnxietyEntry,
        selectedSong: Song?,
        in context: ModelContext
    ) -> Bool {
        let currentSong = entry.songOccurrences?.first?.song

        // Same song — still sync timestamp/source in case the entry was edited
        if selectedSong?.id == currentSong?.id {
            return syncExistingOccurrences(for: entry)
        }

        // Remove existing occurrences, updating old song's timestamp
        if let occurrences = entry.songOccurrences {
            for occ in occurrences {
                occ.song?.updatedAt = Date()
                context.delete(occ)
            }
        }

        // Add new occurrence if a song is selected
        if let song = selectedSong {
            let occurrence = SongOccurrence(
                timestamp: entry.timestamp,
                source: occurrenceSource(for: entry)
            )
            occurrence.song = song
            occurrence.anxietyEntry = entry
            context.insert(occurrence)
            song.updatedAt = Date()
        }

        return true
    }

    /// Updates timestamp and source on existing occurrences to match the entry.
    private static func syncExistingOccurrences(for entry: AnxietyEntry) -> Bool {
        let expectedTimestamp = entry.timestamp
        let expectedSource = occurrenceSource(for: entry)
        var changed = false

        if let occurrences = entry.songOccurrences {
            for occ in occurrences {
                if occ.timestamp != expectedTimestamp {
                    occ.timestamp = expectedTimestamp
                    changed = true
                }
                if occ.source != expectedSource {
                    occ.source = expectedSource
                    changed = true
                }
            }
            if changed {
                occurrences.first?.song?.updatedAt = Date()
            }
        }

        return changed
    }
}
