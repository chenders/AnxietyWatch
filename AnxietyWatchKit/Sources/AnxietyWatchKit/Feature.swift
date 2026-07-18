import Foundation

/// Runtime rollout gates (Spec §7.3).
///
/// Backed by UserDefaults with remote-config override capability.
/// Missing values resolve to the safe, legacy path so offline installs
/// can always communicate with older peers.
///
/// Every flag flip logs an OSLog event and appears on the diagnostics screen.
public enum Feature {
    /// §7.1 Phase 1: BLE actors + pipeline. Gap event branch is dark
    /// until this flag is enabled. Default: false.
    public static var pipelineGapEventsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "pipeline.gapEventsEnabled")
    }

    /// §7.1 Phase 2A: SQLite storage reads. When false, read routes go
    /// back to SwiftData. Default: false.
    public static var sqliteReadsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "storage.sqliteReadsEnabled")
    }

    /// §7.1 Phase 2B: binary WCSession codec (packed rows + zlib).
    /// When false, legacy JSON DTOs are used. Default: false.
    public static var wcBinaryFormatEnabled: Bool {
        UserDefaults.standard.bool(forKey: "wc.binaryFormatEnabled")
    }

    /// §7.1 Phase 2C: delta sync endpoints. When false, legacy REST
    /// remains active. Default: false.
    public static var deltaEnabled: Bool {
        UserDefaults.standard.bool(forKey: "sync.deltaEnabled")
    }

    /// §3.4 Oura BLE: enable Oura Ring 5 BLE IBI streaming.
    /// Requires user-provided 16-byte key extraction. Default: false.
    public static var ouraBLEEnabled: Bool {
        UserDefaults.standard.bool(forKey: "oura.bleEnabled")
    }
}
