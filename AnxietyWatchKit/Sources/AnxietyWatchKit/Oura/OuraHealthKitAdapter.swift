import Foundation
#if canImport(HealthKit)
import HealthKit

public protocol OuraHealthStoreProtocol: Sendable {
    func requestPermissions(share: Set<HKSampleType>?, read: Set<HKObjectType>?) async throws
}

extension HKHealthStore: OuraHealthStoreProtocol {
    public func requestPermissions(share: Set<HKSampleType>?, read: Set<HKObjectType>?) async throws {
#if os(iOS) || os(watchOS)
        try await requestAuthorization(toShare: share ?? [], read: read ?? [])
#endif
    }
}

public actor OuraHealthKitAdapter {
    private let healthStore: OuraHealthStoreProtocol
    
    public init(healthStore: OuraHealthStoreProtocol = HKHealthStore()) {
        self.healthStore = healthStore
    }
    
    public func requestPermissions() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        
        var types: Set<HKObjectType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let spo2 = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { types.insert(spo2) }
        
        try await healthStore.requestPermissions(share: nil, read: types)
    }
}
#endif
