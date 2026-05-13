# Polar H10 Chest Strap

High-fidelity HRV recording from a paired Polar H10. Where Apple Watch HRV is a sampled snapshot (typically a handful of readings during overnight wear, computed by Apple's closed pipeline), the Polar H10 streams **every individual heartbeat interval** over Bluetooth Low Energy and lets the app compute HRV directly. This document covers pairing, what gets recorded, background-mode behavior, sync, and the limits that still apply.

> **Verification needs hardware.** CoreBluetooth peripherals can't be simulated, so end-to-end testing requires an actual Polar H10 paired to an iPhone running the app. The simulator is fine for everything *except* the BLE flow.

---

## What it is

A pipeline that turns a Polar H10 chest strap into the app's reference HRV sensor:

- Beat-to-beat **RR intervals** (the millisecond gap between consecutive heartbeats) stream from the strap at ~1 Hz over the standard Bluetooth `0x180D` Heart Rate service.
- The app buffers RR intervals into 60-second windows and writes one per-minute HRV row per window with time-domain (RMSSD, SDNN, pNN50) and frequency-domain (LF power, HF power, LF/HF ratio) measures.
- Per-session summaries (mean HRV, total RR count, interruption count) land in a `SensorSession` row.
- The raw RR-interval stream is appended to a per-session archive file on disk so the server can re-derive any HRV measure later, even ones the app doesn't compute today.

The Polar data lives alongside HealthKit data — it doesn't replace HRV from the Apple Watch. Both are tagged with a `source` label and surfaced as separate overlays on the trend charts.

---

## Hardware and setup

- **Strap:** Polar H10. The pipeline scans for the standard Bluetooth Heart Rate service (`0x180D`) and doesn't filter on strap model, but only the H10 has been tested end-to-end. Other straps (H9, H7) may advertise the same service, but reliable RR-interval emission isn't guaranteed and beat-to-beat HRV may be degraded or absent.
- **Sensor pads:** moisten before wear; dry pads produce immediate connection drops.
- **iPhone:** any model that runs iOS 18+ (the app's minimum) — the BLE radio is the same across modern devices.
- **No paid Polar account, no Polar Flow app, no Polar SDK.** The app talks to the standard Bluetooth Heart Rate Profile directly via Apple's `CoreBluetooth` framework.

### Pairing

1. Open **Settings → Pair Polar H10** in the app.
2. Wet the strap pads and put it on so the sensor can start advertising.
3. Tap the discovered peripheral in the list — the app remembers it by `CBPeripheral` UUID and reconnects automatically on subsequent sessions.
4. The first connection prompts for Bluetooth permission. Denying it puts the service in `bluetoothUnauthorized` state with a recovery hint pointing at iOS Settings.

The paired identifier is stored in `UserDefaults` keyed on `polarH10.peripheralUUID` / `polarH10.peripheralName`. Unpairing clears both and stops any in-flight session.

---

## On-device data flow

```
Polar H10 (BLE 0x180D ┆ 0x2A37 notify)
       │  HR + 1..n RR intervals every ~1s
       ▼
PolarHRMService           ──── CoreBluetooth ownership, reconnect logic
       │
       ▼
RRIntervalBuffer          ──── rolling 60-second windows of RR intervals
       │
       ├──► RRArchiveWriter ──► <App Support>/rr_archives/<UUID>.rr  (uncompressed raw RR; zlib-compressed at upload)
       │
       ▼
HRVSessionRecorder        ──── computes per-minute HRV every 60s tick
       │
       ├──► HRVReading (SwiftData)     one row per minute
       └──► SensorSession (SwiftData)  one row per wear-session
```

Key behaviors:

- **Per-minute cadence.** `HRVSessionRecorder.tick(at:)` fires every 60 s. A window with fewer than ~30 RR intervals can compute RMSSD/SDNN/pNN50 but not the frequency-domain pieces; in that case `lfPower`, `hfPower`, and `lfHfRatio` are written as `0.0` (a zero sentinel that the LF/HF chart treats as "no data" rather than plotting it as a collapsed physiologic state).
- **Reconnect grace period.** Transient BLE disconnects (rolling over in bed, bathroom break) are absorbed by a backoff schedule (`1, 2, 4, 8, 30, 60, …` seconds, capped at 10 minutes total). Each gap is recorded as a `SensorInterruption` on the `SensorSession` row, but the session does not finalize until the grace period is exhausted.
- **Background-mode recording.** The iOS app declares `bluetooth-central` in `UIBackgroundModes` so the BLE pipeline keeps running when the screen is off or another app is foregrounded. The `CBCentralManager` is initialized with a stable `restoreIdentifier` (`com.anxietywatch.polar-h10`) so iOS can wake the app via `centralManager(_:willRestoreState:)` after a memory-pressure termination and resume the session against the still-open `SensorSession` row.
- **State restoration.** If the app is killed mid-session, the recovery initializer on `HRVSessionRecorder` re-binds to the existing `SensorSession` (the one with `endTime == nil`), rehydrates prior per-minute RMSSDs from the existing `HRVReading` children, and re-establishes the total RR count from `RRArchiveWriter.recordCount` (file size ÷ record size). The recovery path does not replay the archive byte-by-byte — server-side re-derivation is the consumer for that — but the final session summary still covers the whole session because the pre-restart history is recovered from the persisted rows and the archive's size, not just the post-recovery minutes.
- **Dashboard card.** A live status card shows current HR, session duration, the most recent minute's RMSSD, and any active interruption — visible the moment recording starts.

---

## Server sync

Two server tables hold the Polar data; both are mirrored from iOS via `SyncService`:

| Table | What's in it |
|-------|--------------|
| `sensor_sessions` | One row per wear-session: UUID, `source` (the value of `PolarHRMService.sourceLabel`, currently `polar_h10`), `start_time`, `end_time`, `battery_at_start`, `interruption_count`, a `summary_json` JSONB blob, and a nullable `rr_archive` BYTEA column carrying the zlib-compressed raw RR-interval stream |
| `hrv_readings`    | Per-minute rows referencing `sensor_sessions(id)`: RMSSD, SDNN, pNN50, optional LF power / HF power / LF/HF ratio, and a `source` label matching the parent row |

The RR archive is uploaded by `SyncService.uploadPendingRRArchives` whenever a sync run includes the session ID and the archive hasn't been uploaded yet (the gate is `rrArchiveUploadedAt == nil`, not `endTime != nil`). In practice this almost always means "after the session has ended" — sync runs after the session is finalized — but partial-archive uploads of an in-flight session aren't structurally prevented. Re-derivation of new HRV measures (alternative spectral methods, different windowing) can happen entirely server-side without re-pairing the device.

The deployed schema is owned by the Alembic migration in `server/alembic/versions/0005_polar_h10_sessions.py`; `server/schema.sql` is a reference snapshot of the cumulative schema and is not applied by Alembic at deploy time.

---

## What you see in the app

- **Settings → Pair Polar H10** — pairing flow, current connection status, unpair.
- **Dashboard live card** — appears whenever a session is recording. Shows HR, elapsed time, latest minute's RMSSD.
- **Trends → HRV** — the existing Apple Watch HRV line is joined by a Polar SDNN line per overnight session, so two HRV sources are visible side by side.
- **Trends → RMSSD and HF Power cards** — Polar-only cards (Apple Watch doesn't expose these). One mean value per overnight session.
- **Trends → LF/HF detail** — drill into a single session to see per-minute LF power, HF power, and the LF/HF ratio across the night. Sessions ≥ 3 hours are treated as "overnight" by `LFHFAggregator.overnightThresholdSeconds`.

---

## Current status

Shipped end-to-end:

- BLE pairing and foreground recording.
- Background-mode + state restoration across app termination.
- Dashboard live status card.
- Server sync of sessions, per-minute HRV, and the RR archive.
- LF/HF trend chart and per-session drill-down, with Apple Watch HRV overlay.

---

## Known limits

- **Polar H10 only (tested).** The BLE scan accepts any peripheral advertising the standard Heart Rate service `0x180D` and the app doesn't filter by model, but H10 is the only strap that's been exercised end-to-end. Other Polar straps and generic HR sensors may pair; whether they emit RR intervals reliably enough to derive HRV is not guaranteed.
- **No watchOS pairing.** The chest strap pairs with the iPhone, not the Apple Watch — `CBCentralManager` lives in the phone target.
- **Frequency-domain HRV needs density.** Per-minute windows with fewer than ~30 RR intervals (very low HR, or partial dropouts) emit time-domain values only; the chart renders a gap rather than plotting near-zero LF/HF as a real physiologic state.
- **Outlier handling.** The per-minute aggregates trim outliers at the data layer rather than relying on `chartYScale(domain:)` clamping — see `CLAUDE.md`'s notes on Swift Charts + NaN performance on iOS 26 for why.
- **Battery.** Continuous BLE central operation overnight measurably reduces iPhone battery — expect a noticeable hit on an older device.

---

## Future work

- Aggregation across multiple sessions per night (e.g. removed-the-strap-to-pee → put-it-back-on splits into two sessions today).
- Daytime stress check-ins as short ad-hoc sessions, distinct from overnight wear.
- Server-side re-derivation tooling that consumes the RR archive and writes alternative HRV measures back into `hrv_readings`.
- Surfacing interruption metadata (count, total minutes lost) in the session detail view.
