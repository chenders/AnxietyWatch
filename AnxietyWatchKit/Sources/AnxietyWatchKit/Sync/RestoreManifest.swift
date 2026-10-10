import Foundation

/// One sync payload entity and the two independent pieces required to bring it
/// back to a replacement device.
public struct RestoreEntityDescriptor: Sendable, Equatable {
    public let table: String
    public let uploads: Bool
    public let serverQuery: String?
    public let importerID: String?

    public init(
        table: String,
        uploads: Bool,
        serverQuery: String?,
        importerID: String?
    ) {
        self.table = table
        self.uploads = uploads
        self.serverQuery = serverQuery
        self.importerID = importerID
    }
}

/// Cross-layer inventory for the legacy sync payload.
///
/// `table` is the upload payload key. `serverQuery` is the corresponding
/// `/api/data` entity name, which may differ when the legacy wire contract uses
/// different upload and restore names. `importerID` names the app importer.
public struct RestoreManifest: Sendable, Equatable {
    public let entities: [RestoreEntityDescriptor]

    public init(entities: [RestoreEntityDescriptor]) {
        self.entities = entities
    }

    public var uploadedTables: [String] {
        entities.filter(\.uploads).map(\.table).sorted()
    }

    public var missingRoundTrips: [String] {
        entities
            .filter { descriptor in
                descriptor.uploads
                    && (descriptor.serverQuery?.isEmpty != false
                        || descriptor.importerID?.isEmpty != false)
            }
            .map(\.table)
            .sorted()
    }

    public static let production = RestoreManifest(entities: [
        .init(table: "anxietyEntries", uploads: true,
              serverQuery: "anxietyEntries", importerID: "importAnxietyEntries"),
        .init(table: "medicationDefinitions", uploads: true,
              serverQuery: "medicationDefinitions", importerID: "importMedDefinitions"),
        .init(table: "medicationDoses", uploads: true,
              serverQuery: "medicationDoses", importerID: "importMedDoses"),
        .init(table: "cpapSessions", uploads: true,
              serverQuery: "cpapSessions", importerID: "importCPAPSessions"),
        .init(table: "healthSnapshots", uploads: true,
              serverQuery: "healthSnapshots", importerID: "importHealthSnapshots"),
        .init(table: "barometricReadings", uploads: true,
              serverQuery: "barometricReadings", importerID: "importBarometricReadings"),
        .init(table: "clinicalLabResults", uploads: true,
              serverQuery: "clinicalLabResults", importerID: "importClinicalLabResults"),
        .init(table: "pharmacies", uploads: true,
              serverQuery: "pharmacies", importerID: "importPharmacies"),
        .init(table: "prescriptions", uploads: true,
              serverQuery: "prescriptions", importerID: "importPrescriptions"),
        .init(table: "pharmacyCallLogs", uploads: true,
              serverQuery: "pharmacyCallLogs", importerID: "importPharmacyCallLogs"),
        .init(table: "sensorSessions", uploads: true,
              serverQuery: "sensorSessions", importerID: "importSensorSessions"),
        .init(table: "hrvReadings", uploads: true,
              serverQuery: "hrvReadings", importerID: "importHRVReadings"),
        .init(table: "accelSpectrograms", uploads: true,
              serverQuery: "accelSpectrograms", importerID: "importAccelSpectrograms"),
        .init(table: "derivedBreathingRates", uploads: true,
              serverQuery: "derivedBreathingRates", importerID: "importDerivedBreathingRates"),
        .init(table: "songs", uploads: true,
              serverQuery: "songs", importerID: "importSongs"),
        .init(table: "songOccurrences", uploads: true,
              serverQuery: "songOccurrences", importerID: "importSongOccurrences"),
        .init(table: "sleepStageEvents", uploads: true,
              serverQuery: "sleepStageEvents", importerID: "importSleepStageEvents"),
        .init(table: "quantitySamples", uploads: true,
              serverQuery: "quantityHealthSamples", importerID: "restorePagedQuantitySamples"),
    ])
}
