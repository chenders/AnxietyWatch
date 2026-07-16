import os

/// A collection of loggers for different modules in the AnxietyWatchKit framework
public enum Log {
    /// Logger for storage-related operations
    public static let storage = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "storage"
    )
    
    /// Logger for sync-related operations
    public static let sync = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "sync"
    )
    
    /// Logger for HLC (Hybrid Logical Clock) operations
    public static let hlc = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "hlc"
    )
    
    /// Logger for BLE (Bluetooth Low Energy) operations.
    /// HealthKit adapter logs also route here.
    public static let ble = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "ble"
    )

    /// Logger for HealthKit adapter operations. Alias for `ble` for clarity;
    /// use whichever reads more naturally at the call site.
    public static let healthkit = ble

    /// Logger for the Complication Extension read-side. Routed under `wc`
    /// because complication data is written by the WCSession-managed cache writer.
    public static let complication = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "complication"
    )
    
    /// Logger for pipeline operations
    public static let pipeline = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "pipeline"
    )
    
    /// Logger for transport layer operations
    public static let transport = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "transport"
    )
    
    /// Logger for WatchConnectivity operations
    public static let wc = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "wc"
    )
    
    /// Logger for panic protocol events
    public static let panic = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "panic"
    )
    
    /// Logger for migration operations
    public static let migration = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "migration"
    )
    
    /// Logger for diagnostics operations
    public static let diag = Logger(
        subsystem: "com.anxietywatch.kit",
        category: "diag"
    )
}