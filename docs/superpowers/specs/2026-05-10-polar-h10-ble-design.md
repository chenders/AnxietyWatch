# Polar H10 BLE Direct Integration — Design

**Date:** 2026-05-10
**Branch:** `feat/polar-h10-ble`
**Goal:** Capture beat-to-beat RR intervals from a Polar H10 chest strap directly via CoreBluetooth, compute high-fidelity HRV (RMSSD, SDNN, pNN50, LF, HF, LF/HF), and persist them per-minute and per-session — both for on-demand stress checks during the day and for overnight recordings.

## Why direct BLE (not HealthKit / not Polar Flow)

HealthKit has no RR-interval data type. Polar Flow's HealthKit export is HR-only at 1 Hz (verified in prod: `fi.polar.polarflow` source, 991 samples in 16:30, no HRV). The H10's defining advantage — millisecond-resolution RR intervals — only reaches our app if we read GATT directly. The existing `HRVCalculator` already converts RR → time-domain + frequency-domain HRV; the missing piece is a CoreBluetooth source feeding it.

Watch HRV-SDNN in prod averages ~10 samples/day with many nights showing 2–4 — too sparse to support the overnight chart we want. Direct H10 streaming yields ~480 minute-level HRV samples per night plus a continuous LF/HF curve through REM transitions.

## Scope

**In scope (MVP):**
- iPhone-side CoreBluetooth central pairing with H10 over BLE Heart Rate Service (0x180D).
- Two recording modes: on-demand stress check (foreground, 5–30 min) and overnight (manually started, runs while phone is locked).
- Per-minute `HRVReading` rows + per-session `SensorSession` summary + raw RR-interval archive on disk.
- Server schema additions to persist sessions, per-minute readings, and (optional) raw archives.
- Dashboard card + full-screen live session view + first-time pairing flow.

**Out of scope (future):**
- Auto-detect / auto-record when strap is nearby (path C from brainstorming).
- Watch-side BLE.
- Apple-Watch-PPG-vs-Polar-H10 reconciliation logic in the chart (deferred).
- Multi-strap / multi-device pairing.

## Architecture

### Components (iPhone)

| Component | File | Role |
|---|---|---|
| `PolarHRMService` | `AnxietyWatch/Services/PolarHRMService.swift` | Owns `CBCentralManager` with state-restoration ID, parses Heart Rate Measurement (0x2A37) frames, extracts HR + RR intervals. |
| `PolarHRMState` | same file | `@Observable` reference type holding view-facing state (connection status, current HR, last-minute RMSSD, session timer, last error). |
| `RRIntervalBuffer` | `AnxietyWatch/Services/RRIntervalBuffer.swift` | `actor` holding a trailing window of `(timestamp, rrMs)` pairs. Drops anything older than the configured window (60 s). |
| `HRVSessionRecorder` | `AnxietyWatch/Services/HRVSessionRecorder.swift` | Owns one `SensorSession`. Every 60 s, flushes the buffer, calls `HRVCalculator`, writes one `HRVReading`. Tracks interruptions, finalizes session on stop or grace-period expiry. |
| `RRArchiveWriter` | `AnxietyWatch/Services/RRArchiveWriter.swift` | Streams every RR interval to a per-session uncompressed binary file (`Application Support/rr_archives/<sessionID>.rr`). Phase 3 compresses at upload time. |
| `HRVSessionCardView` | `AnxietyWatch/Views/Dashboard/HRVSessionCardView.swift` | Dashboard card: pairing status, last-session summary, Start/Stop, "Pair H10" entry. |
| `HRVSessionLiveView` | `AnxietyWatch/Views/Dashboard/HRVSessionLiveView.swift` | Full-screen modal: live HR (large), session timer, last-minute RMSSD, RR sparkline, Stop. |
| `PolarPairingView` | `AnxietyWatch/Views/Dashboard/PolarPairingView.swift` | One-time pairing: scan list, tap to pair, persist UUID. |

### Threading model

- `CBCentralManager` callbacks run on a dedicated dispatch queue `com.anxietywatch.ble`.
- `RRIntervalBuffer` is an `actor` — all reads/writes are serialized.
- `HRVSessionRecorder` performs computation off-main; SwiftData writes hop to `@MainActor`.
- View state flows through `PolarHRMState` (`@Observable`); views use `@Bindable`.
- `PolarHRMService` is **not** `@Observable` — it's a long-lived service that may outlive any view, especially during background relaunch. Views observe `PolarHRMState`.

### What does not change

- `HRVCalculator.swift` — already accepts `[Double]` RR intervals, returns time-domain and frequency-domain results. No changes.
- `SensorSession` model — already fits.
- `HKWorkoutSession` and other HealthKit code — untouched.

## Data flow

```
Polar H10
    ▼ BLE GATT Notify (HR Service 0x180D, HRM char 0x2A37)
PolarHRMService (parses HR + RR list per packet)
    ▼ async actor send
RRIntervalBuffer (trailing 60s window)
    ├──► RRArchiveWriter.append(ts, rrMs)            → <sessionID>.rr
    └──► every 60s:
            HRVSessionRecorder.flushMinute()
                ▼
            HRVCalculator.timeDomain + frequencyDomain
                ▼
            HRVReading row written (SwiftData)
```

On session finalize:
- `SensorSession.endTime` is set.
- A summary blob (mean/min/max RMSSD across the session, total RR count, gap fraction, interruption count, skipped-minute count) is computed and serialized as JSON into a new `summaryJSON: String?` field on `SensorSession`. JSON keeps the schema flexible while we figure out which derived fields actually matter on the chart side.
- `RRArchiveWriter` flushes any pending bytes and closes the file.
- `SyncService` is notified to enqueue the session, its `HRVReading` rows, and the raw `.rr` archive for upload (Phase 3 applies one-shot compression at upload time).

## BLE specifics

### Heart Rate Measurement frame parsing (characteristic 0x2A37)

Per Bluetooth SIG `Heart_Rate_Measurement.xml`:

- Byte 0 = flags:
  - bit 0 (0x01): HR value format (0 = uint8, 1 = uint16)
  - bits 1–2: sensor contact status (no payload effect)
  - bit 3 (0x08): Energy Expended Present → 2-byte uint16 between HR and RR
  - bit 4 (0x10): RR-Interval Present → trailing list of uint16 values
- Bytes 1–2 (or 1): HR value.
- Optional 2-byte Energy Expended field (when flag bit 3 is set).
- Trailing bytes: zero or more uint16 RR intervals **in 1/1024 s units** — multiply by `1000.0/1024.0` to get ms.

The H10 typically advertises 0–2 RR intervals per packet, sent at ~1 Hz when HR is calm. Each packet's RR intervals correspond to beats that completed since the previous packet, **in order**. Packet timestamp is the parsing timestamp; we attribute RR intervals using cumulative-sum back-projection from packet receipt.

### Pairing & reconnection

- Pairing flow: tap "Pair H10" → start scan filtered to `CBUUID(string: "180D")` → list peripherals advertising that service → user taps → persist `peripheral.identifier.uuidString` to `UserDefaults["polarH10.peripheralUUID"]`.
- Subsequent connects use `central.retrievePeripherals(withIdentifiers:)` — no rescan needed.
- `CBCentralManager` is created with `CBCentralManagerOptionRestoreIdentifierKey: "com.anxietywatch.h10"`. iOS will relaunch the app for connection events when the app is suspended in the background or when the system terminated it (memory pressure / crash). It will **not** relaunch the app after the user manually force-quits via the App Switcher — that's an iOS policy, not a configuration we can change. Phase 2's lifecycle handling needs to surface a "session paused, reopen the app to resume" affordance for that case rather than silently failing to record.
- On `application(_:didFinishLaunchingWithOptions:)` we check `UIApplication.LaunchOptionsKey.bluetoothCentrals` and reconstruct any in-flight `SensorSession` from SwiftData (open-ended session whose `endTime` is nil and whose `startTime` is within the last 24 h).

### Background mode

- Add `bluetooth-central` to `UIBackgroundModes` in Info.plist.
- Add `NSBluetoothAlwaysUsageDescription`: "Anxiety Watch reads beat-to-beat heart-rate intervals from a paired Polar H10 chest strap to compute high-fidelity HRV during stress check-ins and overnight."
- iOS suspends BLE notifications eventually if no I/O activity, but the H10 sends ~1 Hz, well within the keep-alive threshold.

## Data model

### `HRVReading` (existing, additive change)

Add one nullable field:

```swift
var source: String?   // "polar_h10" | "apple_watch_ppg" | nil for legacy rows
```

SwiftData lightweight migration: column defaults to `nil`. Existing rows untouched. New Polar-derived rows always set `"polar_h10"`. PPG-derived rows (when the post-session HKHeartbeatSeries pipeline gets implemented) set `"apple_watch_ppg"`.

### `SensorSession` (existing, additive change)

Add fields:

```swift
var source: String?          // "polar_h10" for new sessions; nil for legacy rows
var summaryJSON: String?     // JSON blob: { rmssdMean, rmssdMin, rmssdMax, rrCount, durationSec, gapFraction, interruptionCount, skippedMinutes }
```

Reuses existing `interruptions: [SensorInterruption]` array.

### Raw RR archive (new, on-disk)

- Path: `<App Support>/rr_archives/<sessionID>.rr`
- Format: uncompressed binary records, fixed 10 bytes each:
  - `uint64 timestamp_ms` big-endian (Unix epoch ms)
  - `uint16 rr_ms` big-endian (must fit uint16; H10 produces 300–2000)
- ~30k records/night × 10 bytes = 300 KB.
- Created on first byte, appended to live, finalized on session end.
- **Phase 1 keeps the on-device format uncompressed.** At ~300 KB/night the streaming-compression machinery isn't worth its complexity; the existing tests would otherwise need to cover gzip framing and partial-file recovery. Compression is applied at upload time in Phase 3 (one-shot via `Data.compressed(using: .zlib)`), not on disk. If the app crashes mid-session, the partial `.rr` file is naturally recoverable — record-aligned binary with no framing.

## Server schema (Alembic migration)

New tables, additive only — no impact on existing endpoints.

```sql
CREATE TABLE sensor_sessions (
    id                  UUID PRIMARY KEY,
    source              TEXT NOT NULL,             -- 'polar_h10'
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ,
    interruption_count  INTEGER NOT NULL DEFAULT 0,
    summary_json        JSONB,
    rr_archive          BYTEA,                      -- raw RR archive (zlib-compressed at upload time); nullable, can be uploaded later
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id)
);

CREATE TABLE hrv_readings (
    id                  UUID PRIMARY KEY,
    session_id          UUID NOT NULL REFERENCES sensor_sessions(id) ON DELETE CASCADE,
    timestamp           TIMESTAMPTZ NOT NULL,
    rmssd               DOUBLE PRECISION NOT NULL,
    sdnn                DOUBLE PRECISION NOT NULL,
    pnn50               DOUBLE PRECISION NOT NULL,
    lf_power            DOUBLE PRECISION,
    hf_power            DOUBLE PRECISION,
    lf_hf_ratio         DOUBLE PRECISION,
    source              TEXT NOT NULL,             -- 'polar_h10'
    source_bundle_id    TEXT,
    UNIQUE (id)
);
CREATE INDEX idx_hrv_readings_session ON hrv_readings (session_id);
CREATE INDEX idx_hrv_readings_timestamp ON hrv_readings (timestamp DESC);
```

`health_snapshots` gets two nullable columns added in a follow-on migration so the chart pipeline can consume Polar HRV without changing the existing `hrv_avg`/`hrv_min` semantics:

```sql
ALTER TABLE health_snapshots ADD COLUMN IF NOT EXISTS hrv_rmssd_avg     DOUBLE PRECISION;
ALTER TABLE health_snapshots ADD COLUMN IF NOT EXISTS hrv_lf_hf_avg     DOUBLE PRECISION;
```

A daily aggregator job (or in-line computation in the existing snapshotter) populates these from `hrv_readings`.

### New endpoints

- `POST /api/sensor_sessions` — upload one session row (id, source, start, end, interruption_count, summary_json).
- `POST /api/hrv_readings` — bulk-upload an array of HRVReading rows belonging to a session.
- `POST /api/sensor_sessions/<id>/rr_archive` — multipart upload of the RR archive. The client compresses the raw `.rr` file with `Data.compressed(using: .zlib)` before upload; the server stores the compressed bytes on `sensor_sessions.rr_archive`.

All authenticated with the existing Bearer-token scheme.

## Lifecycle & error handling

### Pairing failures
- No peripherals advertising 0x180D after 30 s scan: surface "No Polar H10 found nearby. Make sure the strap is wet and worn."
- Connect timeout after pairing: surface "Couldn't connect. If you have Polar Flow open, close it and try again." (Detection: we just saw the advertisement, but `connect()` repeatedly times out → almost always Polar Flow holding the connection.)

### Session lifecycle
- Brief disconnects (≤10 min): silent reconnect with backoff (1, 2, 4, 8, 30 s loop). Recorder keeps session alive. Each gap is appended as a `SensorInterruption(reason: "ble_disconnect", ...)`.
- Long disconnect (>10 min continuous): finalize session, write summary, stop the central. The grace period is configurable; default 600 s.
- User taps Stop: immediate finalize, even mid-minute.
- App force-quit / crash: on next launch, the in-flight `SensorSession` (open `endTime`) is detected. If its `startTime` is recent enough (<24 h) and a peripheral was registered, attempt resume; otherwise finalize with whatever data exists and mark with an "unclean shutdown" interruption.

### HRV computation edge cases
- Window has <2 RR intervals: skip the minute, write nothing. Increment a "skipped minutes" counter on the session summary.
- Window has 2–29 RR intervals: time-domain only. **Phase 1 stores 0.0 for `lfPower`/`hfPower`/`lfHfRatio` on these rows** since `HRVReading`'s frequency-domain fields are non-optional `Double`. This is a known semantic gap — readers can't currently distinguish "0 because not computed" from "0 because legitimately near-zero". Phase 2's chart integration will revisit (likely making these fields `Double?` with a coordinated SwiftData migration plus chart-side handling). Out of scope for the Phase 1 PR since the change ripples through `HRVTrendChart` and `ReportGenerator`.
- Window has ≥30 RR intervals: time-domain + frequency-domain.
- All RR ≤ 250 ms or ≥ 2000 ms: treat as artifact, drop the minute.

### HealthKit dual-write (toggle, default ON)
During an active session, also write `heartRateVariabilitySDNN` samples to HealthKit at minute resolution, source = AnxietyWatch's bundle ID. This lets existing `quantity_health_samples` ingest pick up the strap's HRV with zero changes. The toggle lives in Settings.

## UI (low fidelity — to be iterated)

The brainstorming user direction was explicit: ship something usable, iterate later. So:

- **Dashboard card:** state machine — `notPaired` → "Pair Polar H10"; `paired, idle` → "Last session: 47 ms RMSSD, 7h 22m" + "Start session"; `paired, recording` → live HR + timer + "Stop"; `paired, error` → error message + "Retry".
- **Live session view:** big HR number, big session timer, smaller "RMSSD: 47 ms (last min)", a 60s RR sparkline, Stop button. No fancy layouts in V1.
- **Pairing view:** scan progress, list of advertising peripherals (filtered to those advertising HR Service), tap to pair.

## Testing

### Unit tests (Swift Testing)

| Component | Coverage |
|---|---|
| `RRIntervalBuffer` | window eviction; concurrent appends; flush returns expected; clock injection |
| `RRArchiveWriter` | round-trip encode/decode; out-of-range-RR rejection; 30k-interval overnight scale (validates the 64 KB flush threshold) |
| `PolarHRMService` GATT parser | known good frames from BLE spec examples; H10-captured frame fixture (added during dev); HR uint8 vs uint16; 0/1/2/3 RR intervals; malformed frames reject cleanly |
| `HRVSessionRecorder` | minute-flush logic; session-summary aggregation; interruption tracking; finalize-after-grace-period; <2 / 2–29 / ≥30 RR-interval branches; injected clock + fake buffer |
| `PolarHRMState` | reducers / state transitions |

CoreBluetooth itself is **not** mocked — keep `PolarHRMService` thin enough that all logic worth testing is in the parser + recorder + buffer.

### Server tests (pytest)

- Alembic migration apply + rollback.
- `POST /api/sensor_sessions` happy path + auth failure + duplicate ID.
- `POST /api/hrv_readings` bulk insert + session_id FK violation.
- `POST /api/sensor_sessions/<id>/rr_archive` multipart upload + size limit.

### Manual verification (real H10)

- Pairing flow on physical iPhone with real strap.
- 5-minute foreground session: confirm `HRVReading` rows written, RR archive on disk, sync to prod.
- Overnight session: phone locked, app force-quit-resilient, ~480 readings/night.
- Polar Flow conflict: open Polar Flow during a session, observe graceful handling.
- Battery: monitor iPhone battery delta over an 8-hour session (acceptable: <10% delta).

## Implementation order

1. SwiftData migration: add `source` to `HRVReading`, add `source` + `summaryJSON` to `SensorSession`. Verify existing snapshots load cleanly.
2. `RRIntervalBuffer` actor + tests.
3. `RRArchiveWriter` + tests.
4. `HRVSessionRecorder` (off the BLE path; driven by a fake buffer in tests).
5. `PolarHRMService` parser-only (canned bytes); then real BLE on device.
6. Pairing UI + state persistence.
7. Live session view + Dashboard card.
8. Background mode + state restoration.
9. HealthKit dual-write toggle.
10. Server: Alembic migration + endpoints + tests.
11. `SyncService` extension to ship sessions, readings, and RR archive.
12. Manual verification on real hardware.

## Open questions deferred to implementation

- `summaryJSON` field set is provisional; will be locked once we have a real night's data to look at and know which fields matter on the chart side. Adding fields is non-breaking (JSON readers tolerate it); removing or renaming is.
- `rr_archive` storage on the server: BYTEA on `sensor_sessions` vs. filesystem under the server's data dir. BYTEA is fine at our scale (~30 MB/year). Defaulting to BYTEA; revisit if the table gets large or if backups become awkward.
- Aggregation cadence into `health_snapshots.hrv_rmssd_avg`: in-line update on every `hrv_readings` insert, vs. a nightly batch job. Defaulting to in-line (simpler, no scheduling); revisit if write amplification becomes a problem.

## Risks

- **State restoration is finicky.** The `bluetoothCentrals` launch option only fires for events while the app was suspended; force-quit-then-reopen is on the user. Mitigation: defensive in-flight-session recovery on every launch.
- **CoreBluetooth + SwiftData on the same actor** can deadlock. Mitigation: never call `try context.save()` from inside a CB delegate callback. Always hop to `@MainActor`.
- **Polar Flow conflict** is unavoidable when the user runs both apps. Mitigation: detect, message clearly, don't try to be clever.
- **Apple Watch HR observers** will continue to land samples during a session; the chart needs to learn to prefer Polar-source HRV when both exist for a window. Out of scope for this spec; flag for the chart pipeline.
