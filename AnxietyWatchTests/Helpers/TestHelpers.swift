import Foundation
import SwiftData
@testable import AnxietyWatch

/// Shared test infrastructure. All test files should use these helpers
/// instead of defining their own `makeContainer()`.
enum TestHelpers {
    /// An isolated `UserDefaults` suite with `RestoreMigrationGate` already
    /// resolved — i.e. the normal steady state of any real install that has
    /// finished its restore-vs-fresh decision.
    ///
    /// `SnapshotAggregator.aggregateDay` refuses to write while that decision is
    /// pending (a snapshot row makes the store non-empty and permanently blocks
    /// the restore the gate exists to enable). Aggregator tests are testing
    /// aggregation, not the gate, so they must opt into the resolved state — the
    /// default `.standard` suite has the key unset and every write would no-op.
    ///
    /// Each caller gets its own suite name so state can't leak between tests, or
    /// — because the simulator persists `.standard` across runs — between runs.
    /// The gate test that needs the *unresolved* state uses `gateUnresolvedDefaults`.
    static func gateResolvedDefaults(suite: String = #function) -> UserDefaults {
        let defaults = gateUnresolvedDefaults(suite: suite)
        RestoreMigrationGate.resolve(defaults: defaults)
        return defaults
    }

    /// A pristine, isolated `UserDefaults` suite — gate NOT resolved.
    /// Models a fresh install sitting on the "Restore or Start Fresh?" prompt.
    static func gateUnresolvedDefaults(suite: String = #function) -> UserDefaults {
        let name = "test.\(suite).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create UserDefaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Creates an in-memory ModelContainer with the full app schema.
    /// Uses the production container factory to ensure identical schema
    /// and migration behavior. In-memory stores have no data to migrate.
    static func makeFullContainer() throws -> ModelContainer {
        try AnxietyWatchContainerFactory.makeContainer(storeURL: nil)
    }
}
