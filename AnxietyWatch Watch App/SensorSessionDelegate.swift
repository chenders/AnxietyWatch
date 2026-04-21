// AnxietyWatch Watch App/SensorSessionDelegate.swift
import Foundation
import HealthKit
import WatchKit

/// NSObject delegate handler that forwards HKWorkoutSession and
/// WKExtendedRuntimeSession callbacks to the SensorCaptureSession actor.
final class SensorSessionDelegate: NSObject,
    HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate,
    WKExtendedRuntimeSessionDelegate {

    private let session: SensorCaptureSession

    init(session: SensorCaptureSession) {
        self.session = session
    }

    // MARK: - HKWorkoutSessionDelegate

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { await session.handleWorkoutStateChange(to: toState, from: fromState) }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { await session.handleWorkoutError(error) }
    }

    // MARK: - HKLiveWorkoutBuilderDelegate

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { await session.handleNewHealthData(collectedTypes) }
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        Task { await session.handleExtendedSessionInvalidated(reason: reason) }
    }

    nonisolated func extendedRuntimeSessionDidStart(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {}

    nonisolated func extendedRuntimeSessionWillExpire(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Task { await session.handleExtendedSessionExpiring() }
    }
}
