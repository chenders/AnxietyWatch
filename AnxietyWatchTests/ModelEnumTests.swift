import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for model enum computed properties — verifying raw value mapping
/// and fallback behavior when stored strings don't match any enum case.
struct ModelEnumTests {

    // MARK: - CPAPSession.source

    @Test("CPAPSession source maps 'csv' to .csv")
    func sourceCSV() {
        let session = ModelFactory.cpapSession(importSource: "csv")
        #expect(session.source == .csv)
    }

    @Test("CPAPSession source maps 'caprx' to .caprx")
    func sourceCapRx() {
        let session = ModelFactory.cpapSession(importSource: "caprx")
        #expect(session.source == .caprx)
    }

    @Test("CPAPSession source maps 'manual' to .manual")
    func sourceManual() {
        let session = ModelFactory.cpapSession(importSource: "manual")
        #expect(session.source == .manual)
    }

    @Test("CPAPSession source maps 'oscar' to .oscar")
    func sourceOSCAR() {
        let session = ModelFactory.cpapSession(importSource: "oscar")
        #expect(session.source == .oscar)
    }

    @Test("CPAPSession source falls back to .csv for unknown string")
    func sourceFallback() {
        let session = ModelFactory.cpapSession(importSource: "unknown")
        #expect(session.source == .csv)
    }

    @Test("CPAPSession source falls back to .csv for empty string")
    func sourceEmpty() {
        let session = ModelFactory.cpapSession(importSource: "")
        #expect(session.source == .csv)
    }

    @Test("Setting CPAPSession source updates importSource string")
    func sourceSetterUpdatesRaw() {
        let session = ModelFactory.cpapSession(importSource: "csv")
        session.source = .oscar
        #expect(session.importSource == "oscar")
    }

    // MARK: - PharmacyCallLog.callDirection

    @Test("PharmacyCallLog callDirection maps 'outgoing'")
    func directionOutgoing() {
        let log = ModelFactory.pharmacyCallLog(direction: "outgoing")
        #expect(log.callDirection == .outgoing)
    }

    @Test("PharmacyCallLog callDirection maps 'incoming'")
    func directionIncoming() {
        let log = ModelFactory.pharmacyCallLog(direction: "incoming")
        #expect(log.callDirection == .incoming)
    }

    @Test("PharmacyCallLog callDirection maps 'attempted'")
    func directionAttempted() {
        let log = ModelFactory.pharmacyCallLog(direction: "attempted")
        #expect(log.callDirection == .attempted)
    }

    @Test("PharmacyCallLog callDirection maps 'connected'")
    func directionConnected() {
        let log = ModelFactory.pharmacyCallLog(direction: "connected")
        #expect(log.callDirection == .connected)
    }

    @Test("PharmacyCallLog callDirection maps 'completed'")
    func directionCompleted() {
        let log = ModelFactory.pharmacyCallLog(direction: "completed")
        #expect(log.callDirection == .completed)
    }

    @Test("PharmacyCallLog callDirection falls back to .attempted for unknown string")
    func directionFallback() {
        let log = ModelFactory.pharmacyCallLog(direction: "unknown")
        #expect(log.callDirection == .attempted)
    }

    @Test("Setting PharmacyCallLog callDirection updates direction string")
    func directionSetterUpdatesRaw() {
        let log = ModelFactory.pharmacyCallLog(direction: "attempted")
        log.callDirection = .completed
        #expect(log.direction == "completed")
    }
}
