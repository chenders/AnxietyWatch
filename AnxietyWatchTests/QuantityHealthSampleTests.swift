import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@Suite("QuantityHealthSample initialization")
struct QuantityHealthSampleInitTests {
    @Test("Initializes with required fields and sensible defaults")
    func initDefaults() {
        let timestamp = Date(timeIntervalSince1970: 1_767_225_600)
        let sample = QuantityHealthSample(
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 142.0,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        #expect(sample.timestamp == timestamp)
        #expect(sample.metricType == "HKQuantityTypeIdentifierBloodGlucose")
        #expect(sample.value == 142.0)
        #expect(sample.unitString == "mg/dL")
        #expect(sample.sourceBundleID == "com.dexcom.stelo")
        #expect(sample.sourceName == "Stelo")
        #expect(sample.deviceModel == nil)
        #expect(sample.groupID == nil)
        #expect(sample.syncedToServer == false)
        // createdAt defaults to .now — within a few seconds of construction
        #expect(abs(sample.createdAt.timeIntervalSinceNow) < 5)
    }

    @Test("groupID is nil by default and can be set to link two BP rows")
    func bpGroupIDLink() {
        let groupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_767_225_600)
        let sys = QuantityHealthSample(
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodPressureSystolic",
            value: 128,
            unitString: "mmHg",
            sourceBundleID: "com.withings.wiscale2",
            sourceName: "Withings",
            groupID: groupID
        )
        let dia = QuantityHealthSample(
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodPressureDiastolic",
            value: 82,
            unitString: "mmHg",
            sourceBundleID: "com.withings.wiscale2",
            sourceName: "Withings",
            groupID: groupID
        )
        #expect(sys.groupID == groupID)
        #expect(dia.groupID == groupID)
        #expect(sys.groupID == dia.groupID)
    }
}

@Suite("QuantityHealthSample idempotency")
struct QuantityHealthSampleIdempotencyTests {
    @Test("Inserting two rows with the same id results in one row")
    func sameIDDedupes() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let sharedID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_767_225_600)

        let first = QuantityHealthSample(
            id: sharedID,
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 142.0,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        context.insert(first)
        try context.save()

        let second = QuantityHealthSample(
            id: sharedID,
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 142.0,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        context.insert(second)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>())
        #expect(rows.count == 1)
    }

    @Test("Different ids with identical natural keys produce two rows")
    func differentIDsNotDeduped() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let timestamp = Date(timeIntervalSince1970: 1_767_225_600)
        let a = QuantityHealthSample(
            id: UUID(),
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 142.0,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        let b = QuantityHealthSample(
            id: UUID(),
            timestamp: timestamp,
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: 142.0,
            unitString: "mg/dL",
            sourceBundleID: "com.dexcom.stelo",
            sourceName: "Stelo"
        )
        context.insert(a)
        context.insert(b)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>())
        #expect(rows.count == 2)
    }
}
