import CallKit
import SwiftData
import UIKit

/// Observes phone calls placed to pharmacies and logs them in SwiftData.
@Observable
final class PharmacyCallService: NSObject, CXCallObserverDelegate {

    static let shared = PharmacyCallService()

    private let callObserver = CXCallObserver()

    // State for tracking the in-progress call
    private var pendingCallLogId: UUID?
    private var callStartTime: Date?
    private var dialTimestamp: Date?
    private var activeModelContext: ModelContext?
    private var timeoutTask: Task<Void, Never>?

    override private init() {
        super.init()
    }

    /// Begin listening for call state changes.
    func startObserving() {
        callObserver.setDelegate(self, queue: nil)
    }

    // MARK: - Initiate a Call

    /// Dials the pharmacy's phone number, creates a preliminary call log, and
    /// starts observing the call lifecycle via CallKit.
    func initiateCall(to pharmacy: Pharmacy, modelContext: ModelContext) {
        let cleanedNumber = pharmacy.phoneNumber
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        guard !cleanedNumber.isEmpty,
              let url = URL(string: "tel:\(cleanedNumber)") else { return }

        let log = PharmacyCallLog(
            direction: "attempted",
            pharmacyName: pharmacy.name,
            pharmacy: pharmacy
        )
        modelContext.insert(log)

        pendingCallLogId = log.id
        dialTimestamp = Date.now
        callStartTime = nil
        activeModelContext = modelContext

        UIApplication.shared.open(url)

        // If no connection detected within 30 seconds, leave as "attempted"
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.handleTimeout()
            }
        }
    }

    // MARK: - Manual Logging

    /// Creates a call log entry without placing an actual phone call.
    func logManualCall(
        pharmacy: Pharmacy,
        direction: String,
        notes: String,
        modelContext: ModelContext
    ) {
        let log = PharmacyCallLog(
            direction: direction,
            pharmacyName: pharmacy.name,
            notes: notes,
            pharmacy: pharmacy
        )
        modelContext.insert(log)
    }

    // MARK: - CXCallObserverDelegate

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in
            self?.handleCallChanged(call)
        }
    }

    // MARK: - Private

    @MainActor
    private func handleCallChanged(_ call: CXCall) {
        guard let logId = pendingCallLogId,
              let context = activeModelContext else { return }

        if call.hasConnected && !call.hasEnded {
            // Call connected
            callStartTime = Date.now
            timeoutTask?.cancel()
            updateLog(id: logId, in: context) { log in
                log.direction = "connected"
            }
        }

        if call.hasEnded {
            // Call ended — compute duration if we ever connected
            timeoutTask?.cancel()
            let duration: Int? = callStartTime.map { start in
                Int(Date.now.timeIntervalSince(start))
            }
            updateLog(id: logId, in: context) { log in
                log.direction = "completed"
                log.durationSeconds = duration
            }
            resetCallState()
        }
    }

    @MainActor
    private func handleTimeout() {
        // If we still have a pending call that hasn't progressed, leave it as "attempted"
        guard pendingCallLogId != nil else { return }
        resetCallState()
    }

    private func resetCallState() {
        pendingCallLogId = nil
        callStartTime = nil
        dialTimestamp = nil
        activeModelContext = nil
        timeoutTask = nil
    }

    /// Fetches the pending call log by ID and applies a mutation.
    @MainActor
    private func updateLog(
        id: UUID,
        in context: ModelContext,
        apply: (PharmacyCallLog) -> Void
    ) {
        let predicate = #Predicate<PharmacyCallLog> { $0.id == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let log = try? context.fetch(descriptor).first else { return }
        apply(log)
    }
}
