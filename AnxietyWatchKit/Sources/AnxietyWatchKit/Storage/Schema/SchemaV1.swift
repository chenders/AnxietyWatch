import Foundation
import GRDB

/// Schema version 1 for the time-series database
public enum SchemaV1 {
    /// The schema version number
    public static let version: Int = 1
    
    /// All SQL statements needed to create the schema
    public static let allStatements: [String] = [
        // samples table
        """
        CREATE TABLE samples (
          source        INTEGER NOT NULL,
          type          INTEGER NOT NULL,
          timestamp     REAL    NOT NULL,
          value         REAL    NOT NULL,
          extra         BLOB,
          hlc_physical  INTEGER NOT NULL,
          hlc_logical   INTEGER NOT NULL,
          node_id       BLOB    NOT NULL,
          PRIMARY KEY (source, type, timestamp)
        ) WITHOUT ROWID, STRICT
        """,
        
        // idx_samples_hlc index
        """
        CREATE INDEX idx_samples_hlc
          ON samples(node_id, hlc_physical, hlc_logical)
        """,
        
        // samples_1min table
        """
        CREATE TABLE samples_1min (
          source INTEGER NOT NULL, type INTEGER NOT NULL, minute_bucket INTEGER NOT NULL,
          value REAL NOT NULL, sample_count INTEGER NOT NULL,
          hlc_physical INTEGER NOT NULL, hlc_logical INTEGER NOT NULL, node_id BLOB NOT NULL,
          PRIMARY KEY (source, type, minute_bucket)
          CHECK(sample_count >= 1)  -- Catch downsampler bugs
        ) WITHOUT ROWID, STRICT
        """,
        
        // idx_samples_1min_hlc index
        """
        CREATE INDEX idx_samples_1min_hlc ON samples_1min(node_id, hlc_physical, hlc_logical)
        """,
        
        // sample_tombstones table
        """
        CREATE TABLE sample_tombstones (
          source            INTEGER NOT NULL,
          type              INTEGER NOT NULL,
          ts_start          REAL    NOT NULL,
          ts_end            REAL    NOT NULL,
          hlc_physical      INTEGER NOT NULL,
          hlc_logical       INTEGER NOT NULL,
          node_id           BLOB    NOT NULL,
          dropped_row_count INTEGER NOT NULL,
          reason            TEXT    NOT NULL CHECK (reason IN ('memory_panic','corruption','manual','retention','unacked_overflow')),
          PRIMARY KEY (source, type, ts_start, hlc_physical, hlc_logical, node_id)
        ) WITHOUT ROWID, STRICT
        """,
        
        // idx_sample_tombstones_hlc index
        """
        CREATE INDEX idx_sample_tombstones_hlc
          ON sample_tombstones(node_id, hlc_physical, hlc_logical)
        """,
        
        // _sync_log table
        """
        CREATE TABLE _sync_log (
          table_name    TEXT    NOT NULL,
          row_pk        TEXT    NOT NULL,
          hlc_physical  INTEGER NOT NULL,
          hlc_logical   INTEGER NOT NULL,
          node_id       BLOB    NOT NULL,
          operation     TEXT    NOT NULL CHECK (operation IN ('upsert','delete')),
          PRIMARY KEY (table_name, row_pk)
        ) WITHOUT ROWID, STRICT
        -- TODO: hlc_now_pt/hlc_now_lc/hlc_now_node SQLite UDFs registered by DatabaseManager.open() when HLC service lands.
        """,
        
        // _backfill_progress table
        """
        CREATE TABLE _backfill_progress (
          source  INTEGER NOT NULL,
          type    INTEGER NOT NULL,
          last_ts REAL    NOT NULL,
          PRIMARY KEY (source, type)
        ) WITHOUT ROWID, STRICT
        """,
        
        // _sync_quarantine table
        """
        CREATE TABLE _sync_quarantine (
          table_name    TEXT    NOT NULL,
          row_pk        TEXT    NOT NULL,
          hlc_physical  INTEGER NOT NULL,
          hlc_logical   INTEGER NOT NULL,
          node_id       BLOB    NOT NULL,
          reason        TEXT    NOT NULL,
          payload       BLOB    NOT NULL,
          -- Local wall-clock at quarantine time (ms since Unix epoch). Used for
          -- diagnostics ordering because hlc_physical is by definition untrusted
          -- on rows that got quarantined (drift-exceeded).
          captured_at   INTEGER NOT NULL DEFAULT (CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)),
          PRIMARY KEY (table_name, row_pk, hlc_physical, hlc_logical, node_id)
        ) WITHOUT ROWID, STRICT
        """
    ]
    
    /// The PRAGMA statement to set the schema version
    public static let schemaVersionPragma = "PRAGMA user_version = 1;"
    
    /// Applies the schema to the given database
    /// - Parameter db: The database to apply the schema to
    public static func apply(to db: Database) throws {
        // Wrap all DDL in a savepoint (which nests inside any outer
        // transaction opened by GRDB's write block) so a mid-apply failure
        // rolls back cleanly without leaving a half-built schema.
        try db.inSavepoint {
            for statement in allStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: schemaVersionPragma)
            return .commit
        }
    }
}