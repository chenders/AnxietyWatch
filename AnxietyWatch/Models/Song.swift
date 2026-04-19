import Foundation
import SwiftData

@Model
final class Song {
    var id: UUID
    /// Maps to songs.id on the server
    var serverId: Int?
    var geniusId: Int?
    var title: String
    var artist: String
    var album: String?
    var albumArtURL: String?
    var geniusURL: String?
    var lyrics: String?
    var lyricsSource: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SongOccurrence.song)
    var occurrences: [SongOccurrence]

    init(
        title: String,
        artist: String,
        album: String? = nil,
        geniusId: Int? = nil,
        albumArtURL: String? = nil,
        geniusURL: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.artist = artist
        self.album = album
        self.geniusId = geniusId
        self.albumArtURL = albumArtURL
        self.geniusURL = geniusURL
        self.createdAt = Date()
        self.updatedAt = Date()
        self.occurrences = []
    }
}
