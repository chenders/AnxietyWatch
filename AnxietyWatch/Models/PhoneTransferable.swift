import Foundation

/// A watch-captured sensor row that is transferred to the phone once.
///
/// The Watch batches these to the phone via `WCSession.transferFile` on a
/// timer. `transferredToPhone` is flipped true only when a transfer actually
/// COMPLETES, so an un-transferred row is always eligible again — nothing is
/// ever skipped by a timestamp comparison, which a backward system-clock step
/// (NTP resync) could otherwise make permanently unfetchable (F-018). A row
/// that is re-fetched after an interrupted transfer is at worst re-sent, never
/// lost — but note the phone must NOT rely on `#Unique(\.id)` alone to dedup a
/// re-send: a blind upsert re-writes stateful fields (e.g. HRVReading's
/// `syncedToServer`), so `PhoneConnectivityManager.ingestSensorPayload` skips
/// ids that already exist instead (F-096).
protocol PhoneTransferable: AnyObject {
    var transferredToPhone: Bool { get set }
}
