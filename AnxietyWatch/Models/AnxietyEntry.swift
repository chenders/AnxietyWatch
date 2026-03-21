import Foundation
import SwiftData

@Model
final class AnxietyEntry {
    var id: UUID
    var timestamp: Date
    /// Subjective anxiety severity, 1 (minimal) to 10 (severe)
    var severity: Int
    var notes: String
    /// Freeform tags for categorization (e.g. "work", "social", "trigger:caffeine")
    var tags: [String]
    var locationLatitude: Double?
    var locationLongitude: Double?

    init(
        timestamp: Date = .now,
        severity: Int = 5,
        notes: String = "",
        tags: [String] = []
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.severity = severity
        self.notes = notes
        self.tags = tags
    }
}
