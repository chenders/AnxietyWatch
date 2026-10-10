import Foundation

/// Owns the end-to-end work that follows a confirmed SQLite corruption event.
///
/// `DatabaseManager` remains responsible for replacing the SQLite files and
/// recreating the schema. This coordinator owns the higher-level recovery
/// contract: publish UI state, restore server-backed rows, ask the app to
/// rederive HealthKit-backed rows, and keep the Keychain-provided node identity
/// stable throughout the replacement.
public actor CorruptionRecoveryCoordinator {
    public enum RecoveryStage: Sendable, Equatable {
        case databaseReplacement
        case serverRestore
        case healthKitRederivation
    }

    public enum State: Sendable, Equatable {
        case idle
        case replacingStore
        case restoringFromServer
        case rederivingHealthKit
        case recovered
        case requiresUserAction
        case failed(stage: RecoveryStage)
    }

    public enum RecoveryError: Error, Sendable, Equatable {
        case restorationFailed
    }

    public typealias RecoveryOperation = @Sendable () async throws -> Void

    private let database: DatabaseManager
    private let stableNodeIdentity: Data
    private let restoreFromServer: RecoveryOperation
    private let rederiveHealthKit: RecoveryOperation
    private let stateContinuation: AsyncStream<State>.Continuation

    private var restorationFailed = false
    public private(set) var currentState: State = .idle
    public private(set) var stateHistory: [State] = [.idle]
    public nonisolated let states: AsyncStream<State>

    public init(
        database: DatabaseManager,
        nodeID: Data,
        restoreFromServer: @escaping RecoveryOperation,
        rederiveHealthKit: @escaping RecoveryOperation
    ) {
        self.database = database
        self.stableNodeIdentity = nodeID
        self.restoreFromServer = restoreFromServer
        self.rederiveHealthKit = rederiveHealthKit

        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        self.states = stream
        self.stateContinuation = continuation
        continuation.yield(.idle)
    }

    /// The immutable identity supplied from Keychain at process startup.
    /// Database replacement never regenerates or persists this value.
    public var nodeIdentity: Data {
        stableNodeIdentity
    }

    /// Installs this coordinator as the single post-replacement owner.
    /// Calling it more than once is harmless; `DatabaseManager` keeps one hook.
    public func bootstrap() async {
        await database.setPostRecoveryHook { [weak self] databaseError in
            await self?.completeRecovery(after: databaseError)
        }
    }

    /// Runs an explicit corruption recovery. Automatic recovery initiated by
    /// `DatabaseManager.open()` uses the same installed post-recovery hook.
    public func recover() async throws {
        restorationFailed = false
        publish(.replacingStore)

        do {
            try await database.recoverFromCorruption()
        } catch DatabaseManager.DatabaseError.corruptionThresholdExceeded {
            publish(.requiresUserAction)
            throw DatabaseManager.DatabaseError.corruptionThresholdExceeded
        } catch {
            if !restorationFailed {
                publish(.failed(stage: .databaseReplacement))
            }
            throw error
        }

        if restorationFailed {
            throw RecoveryError.restorationFailed
        }
    }

    /// Clears a tripped breaker only after an explicit user decision, then
    /// performs one new recovery attempt.
    public func acknowledgeAndRecover() async throws {
        await database.acknowledgeCorruptionCircuit()
        try await recover()
    }

    private func completeRecovery(after databaseError: Error?) async {
        if databaseError != nil {
            restorationFailed = true
            publish(.failed(stage: .databaseReplacement))
            return
        }

        do {
            publish(.restoringFromServer)
            try await restoreFromServer()

            publish(.rederivingHealthKit)
            try await rederiveHealthKit()

            publish(.recovered)
        } catch {
            restorationFailed = true
            switch currentState {
            case .restoringFromServer:
                publish(.failed(stage: .serverRestore))
            case .rederivingHealthKit:
                publish(.failed(stage: .healthKitRederivation))
            default:
                publish(.failed(stage: .databaseReplacement))
            }
        }
    }

    private func publish(_ state: State) {
        guard currentState != state else { return }
        currentState = state
        stateHistory.append(state)
        stateContinuation.yield(state)
    }
}
