import Testing
@testable import AnxietyWatchKit

@Suite("Restore manifest")
struct RestoreManifestTests {
    @Test("missing round trips report exact uploaded table names")
    func missingRoundTripsReportExactNames() {
        let manifest = RestoreManifest(entities: [
            RestoreEntityDescriptor(
                table: "complete",
                uploads: true,
                serverQuery: "complete",
                importerID: "importComplete"
            ),
            RestoreEntityDescriptor(
                table: "missingServer",
                uploads: true,
                serverQuery: nil,
                importerID: "importMissingServer"
            ),
            RestoreEntityDescriptor(
                table: "missingImporter",
                uploads: true,
                serverQuery: "missingImporter",
                importerID: nil
            ),
            RestoreEntityDescriptor(
                table: "missingBoth",
                uploads: true,
                serverQuery: nil,
                importerID: nil
            ),
            RestoreEntityDescriptor(
                table: "downloadOnly",
                uploads: false,
                serverQuery: nil,
                importerID: nil
            ),
        ])

        #expect(manifest.missingRoundTrips == [
            "missingBoth", "missingImporter", "missingServer"
        ])
    }

    @Test("production upload inventory is complete")
    func productionInventoryIsComplete() {
        #expect(RestoreManifest.production.missingRoundTrips.isEmpty)
    }

    @Test("production manifest covers every legacy sync payload entity")
    func productionManifestCoversLegacyPayload() {
        #expect(Set(RestoreManifest.production.uploadedTables) == [
            "accelSpectrograms",
            "anxietyEntries",
            "barometricReadings",
            "clinicalLabResults",
            "cpapSessions",
            "derivedBreathingRates",
            "healthSnapshots",
            "hrvReadings",
            "medicationDefinitions",
            "medicationDoses",
            "pharmacies",
            "pharmacyCallLogs",
            "prescriptions",
            "quantitySamples",
            "sensorSessions",
            "sleepStageEvents",
            "songOccurrences",
            "songs",
        ])
    }
}
