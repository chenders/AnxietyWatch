import Foundation
import SwiftData

@Model
final class PharmacyCallLog {
    var id: UUID
    var timestamp: Date
    /// "outgoing", "incoming", "attempted", "connected", or "completed"
    var direction: String
    /// Denormalized — preserves the name even if the pharmacy is later deleted
    var pharmacyName: String
    var notes: String
    /// Duration in seconds, populated when call completes
    var durationSeconds: Int?
    var pharmacy: Pharmacy?

    init(
        timestamp: Date = .now,
        direction: String = "attempted",
        pharmacyName: String,
        notes: String = "",
        durationSeconds: Int? = nil,
        pharmacy: Pharmacy? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.direction = direction
        self.pharmacyName = pharmacyName
        self.notes = notes
        self.durationSeconds = durationSeconds
        self.pharmacy = pharmacy
    }
}
