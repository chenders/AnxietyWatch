import Foundation
import SwiftData

@Model
final class Pharmacy {
    var id: UUID
    var name: String
    var address: String
    var phoneNumber: String
    /// Latitude from MapKit search result, if available
    var latitude: Double?
    /// Longitude from MapKit search result, if available
    var longitude: Double?
    var notes: String
    var isActive: Bool
    @Relationship(deleteRule: .nullify, inverse: \Prescription.pharmacy)
    var prescriptions: [Prescription]
    @Relationship(deleteRule: .nullify, inverse: \PharmacyCallLog.pharmacy)
    var callLogs: [PharmacyCallLog]

    init(
        name: String,
        address: String = "",
        phoneNumber: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        notes: String = "",
        isActive: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.phoneNumber = phoneNumber
        self.latitude = latitude
        self.longitude = longitude
        self.notes = notes
        self.isActive = isActive
        self.prescriptions = []
        self.callLogs = []
    }
}
