import Foundation
import SwiftData

@Model
final class SongOccurrence {
    var id: UUID
    var timestamp: Date
    /// "journal", "checkin", or "standalone"
    var source: String?
    var notes: String?

    var song: Song?

    @Relationship(deleteRule: .nullify)
    var anxietyEntry: AnxietyEntry?

    init(timestamp: Date = .now, source: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.source = source
    }
}
