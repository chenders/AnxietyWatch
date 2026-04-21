// AnxietyWatch Watch App/SensorCaptureSession.swift
import CoreMotion
import HealthKit
import os
import SwiftData
import WatchKit

/// Manages an invisible HKWorkoutSession(.mindAndBody) for continuous sensor capture.
/// Produces HRVReading, AccelSpectrogram, and DerivedBreathingRate in real time.
actor SensorCaptureSession {
    static let shared = SensorCaptureSession()

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var extendedSession: WKExtendedRuntimeSession?
    private var delegateHandler: SensorSessionDelegate?
    private var accelTask: Task<Void, Never>?

    private(set) var isRunning = false
    private var currentSessionID: UUID?

    // Accelerometer buffer: accumulates until 10-second window is full
    private static let accelSampleRate: Float = 200.0
    private static let accelWindowSamples = 2000 // 10 seconds at 200Hz
    private var accelX = [Float]()
    private var accelY = [Float]()
    private var accelZ = [Float]()
    private var windowStartTime = Date()

    // Pending computed results waiting to be flushed to SwiftData
    private var pendingSpectrograms = [AccelSpectrogram]()
    private var pendingBreathingRates = [DerivedBreathingRate]()

    private let log = Logger(subsystem: "AnxietyWatch", category: "SensorCapture")

    // MARK: - Lifecycle

    func start(modelContainer: ModelContainer) async throws {
        guard !isRunning else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let liveBuilder = session.associatedWorkoutBuilder()
        liveBuilder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore, workoutConfiguration: config
        )

        let handler = SensorSessionDelegate(session: self)
        session.delegate = handler
        liveBuilder.delegate = handler

        self.workoutSession = session
        self.builder = liveBuilder
        self.delegateHandler = handler

        session.startActivity(with: .now)
        do {
            try await liveBuilder.beginCollection(at: .now)
        } catch {
            // Clean up the already-started workout session
            session.end()
            self.workoutSession = nil
            self.builder = nil
            self.delegateHandler = nil
            throw error
        }

        // Start accelerometer stream
        if CMBatchedSensorManager.isAccelerometerSupported {
            accelTask = Task { await processAccelerometerStream() }
        }

        // Extended runtime for persistence across app suspension
        startExtendedSession()

        // Record session in SwiftData
        let context = ModelContext(modelContainer)
        let rawBattery = WKInterfaceDevice.current().batteryLevel
        let batteryLevel = rawBattery >= 0 ? Int(rawBattery * 100) : 0
        let sessionModel = SensorSession(startTime: .now, batteryAtStart: batteryLevel)
        context.insert(sessionModel)
        try context.save()
        currentSessionID = sessionModel.id

        isRunning = true
        windowStartTime = .now
        log.info("Sensor capture started")
    }

    func stop(modelContainer: ModelContainer) async {
        guard isRunning else { return }

        accelTask?.cancel()
        accelTask = nil
        if let builder {
            builder.discardWorkout()
        }
        workoutSession?.end()
        extendedSession?.invalidate()

        // Finalize session record
        let context = ModelContext(modelContainer)
        if let sessionID = currentSessionID {
            let descriptor = FetchDescriptor<SensorSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            if let sessionModel = try? context.fetch(descriptor).first {
                sessionModel.endTime = .now
                let rawEnd = WKInterfaceDevice.current().batteryLevel
                sessionModel.batteryAtEnd = rawEnd >= 0 ? Int(rawEnd * 100) : 0
                try? context.save()
            }
        }

        isRunning = false
        workoutSession = nil
        builder = nil
        extendedSession = nil
        delegateHandler = nil
        currentSessionID = nil
        accelX.removeAll()
        accelY.removeAll()
        accelZ.removeAll()
        log.info("Sensor capture stopped")
    }

    // MARK: - Extended Runtime Chaining

    private func startExtendedSession() {
        let extended = WKExtendedRuntimeSession()
        extended.delegate = delegateHandler
        extended.start()
        self.extendedSession = extended
    }

    func handleExtendedSessionExpiring() {
        // Invalidate current session before starting the replacement
        extendedSession?.invalidate()
        startExtendedSession()
        log.debug("Extended session chained")
    }

    func handleExtendedSessionInvalidated(reason: WKExtendedRuntimeSessionInvalidationReason) {
        if isRunning {
            startExtendedSession()
            log.debug("Extended session restarted after invalidation: \(String(describing: reason))")
        }
    }

    // MARK: - Workout State

    func handleWorkoutStateChange(to: HKWorkoutSessionState, from: HKWorkoutSessionState) {
        log.debug("Workout state: \(String(describing: from)) → \(String(describing: to))")
    }

    func handleWorkoutError(_ error: Error) {
        log.error("Workout session error: \(error.localizedDescription)")
    }

    func handleNewHealthData(_ types: Set<HKSampleType>) {
        // Heart rate data arrives here via the live builder.
        // For real-time HRV, we'd extract HR samples and compute intervals.
        // Full HRV computation happens post-session via queryHeartbeatSeries.
    }

    // MARK: - Accelerometer Processing

    private func processAccelerometerStream() async {
        let manager = CMBatchedSensorManager()
        do {
            for try await batch in manager.accelerometerUpdates() {
                for data in batch {
                    accelX.append(Float(data.acceleration.x))
                    accelY.append(Float(data.acceleration.y))
                    accelZ.append(Float(data.acceleration.z))

                    // Process full 10-second windows
                    if accelX.count >= Self.accelWindowSamples {
                        processAccelWindow()
                    }
                }
            }
        } catch {
            log.error("Accelerometer stream error: \(error.localizedDescription)")
        }
    }

    private func processAccelWindow() {
        let x = Array(accelX.prefix(Self.accelWindowSamples))
        let y = Array(accelY.prefix(Self.accelWindowSamples))
        let z = Array(accelZ.prefix(Self.accelWindowSamples))

        accelX.removeFirst(Self.accelWindowSamples)
        accelY.removeFirst(Self.accelWindowSamples)
        accelZ.removeFirst(Self.accelWindowSamples)

        if let result = AccelerometerProcessor.processWindow(
            x: x, y: y, z: z, sampleRate: Self.accelSampleRate
        ) {
            let spec = AccelSpectrogram(
                timestamp: windowStartTime,
                tremorBandPower: result.tremorBandPower,
                breathingBandPower: result.breathingBandPower,
                fidgetBandPower: result.fidgetBandPower,
                activityLevel: result.activityLevel,
                sensorSessionID: currentSessionID
            )
            pendingSpectrograms.append(spec)
        }

        if let breathing = AccelerometerProcessor.estimateBreathingRate(
            x: x, y: y, z: z, sampleRate: Self.accelSampleRate
        ) {
            let rate = DerivedBreathingRate(
                timestamp: windowStartTime,
                breathsPerMinute: breathing.breathsPerMinute,
                confidence: breathing.confidence,
                source: "accelerometer",
                sensorSessionID: currentSessionID
            )
            pendingBreathingRates.append(rate)
        }

        windowStartTime = .now
    }

    // MARK: - Persistence

    /// Flush accumulated spectrograms and breathing rates to SwiftData.
    /// Call periodically (e.g., every 60 seconds) from the watch app.
    func flushPending(to context: ModelContext) throws {
        for s in pendingSpectrograms { context.insert(s) }
        for b in pendingBreathingRates { context.insert(b) }
        if !pendingSpectrograms.isEmpty || !pendingBreathingRates.isEmpty {
            try context.save()
            log.debug("Flushed \(self.pendingSpectrograms.count) spectrograms, \(self.pendingBreathingRates.count) breathing rates")
        }
        pendingSpectrograms.removeAll()
        pendingBreathingRates.removeAll()
    }
}
