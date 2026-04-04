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
    /// The medication dose that triggered this anxiety entry (nil for manual entries)
    var triggerDose: MedicationDose?
    /// True if this is a 30-minute follow-up entry (vs the initial at-dosing entry).
    /// Optional for migration — nil treated as false for historical entries.
    var isFollowUp: Bool?
    /// Origin of this entry: nil/"user" (manual), "dose_followup", or "random_checkin".
    /// Optional for migration — nil treated as "user" for historical entries.
    var source: String?

    init(
        timestamp: Date = .now,
        severity: Int = 5,
        notes: String = "",
        tags: [String] = [],
        triggerDose: MedicationDose? = nil,
        isFollowUp: Bool = false,
        source: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.severity = severity
        self.notes = notes
        self.tags = tags
        self.isFollowUp = isFollowUp
        self.triggerDose = triggerDose
        self.source = source
    }
}
