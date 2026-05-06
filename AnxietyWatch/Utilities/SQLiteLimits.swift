import Foundation

/// SQLite-imposed limits we have to honor when SwiftData lowers Swift
/// predicates onto the underlying SQLite query layer. SwiftData lowers
/// `Set.contains(...)` to a parameterized `IN(?, ?, ...)` query, and SQLite's
/// default `SQLITE_MAX_VARIABLE_NUMBER` is 999. Exceeding the limit makes the
/// fetch fail, which silently breaks the mirror/sync flag step and causes the
/// caller to retry the same window forever.
///
/// Centralising the constant prevents drift between `HealthDataCoordinator`'s
/// mirror prefetch and `SyncService`'s post-upload flag step — both perform
/// `Set<UUID>`-keyed `IN` lookups and need to chunk identically.
enum SQLiteLimits {
    /// Maximum number of UUIDs to embed in a single `IN(...)` predicate. With
    /// CGM volumes (~288 samples/day × 7-day initial lookback ≈ 2 016 samples
    /// per pass) a single predicate easily exceeds SQLite's 999-parameter
    /// limit. 900 leaves headroom for any internal SwiftData parameters that
    /// piggyback on the IN list.
    static let predicateBatchSize = 900
}
