# EMAY Overnight Pulse Oximeter

Import overnight SpO2 and pulse rate from an [EMAY SleepO2](https://emayinc.com/) wrist or finger pulse oximeter by sharing its CSV export into the app. The EMAY records ~1 Hz samples for the full night — typically 30–40k rows per session — and the import pipeline turns those into per-sample `QuantityHealthSample` rows tagged with the EMAY bundle ID so they dedupe cleanly against samples the EMAY iOS app writes to HealthKit.

> **Verification needs hardware.** This pipeline needs an actual EMAY device's CSV export to round-trip. The CSV format is stable across the SleepO2 product line, but corner cases (multi-night exports, abbreviated headers) only show up against real recordings.

---

## What it is

EMAY oximeters are an inexpensive alternative to a sleep-lab study for capturing overnight desaturation patterns. The device records continuously while you sleep and lets you export the night's data as a CSV from its iOS companion app via the standard share sheet.

Anxiety Watch accepts that CSV and writes it into the same SwiftData store that holds HealthKit samples, so EMAY readings appear in the dashboard, trend charts, exports, and clinical reports alongside Apple Watch and CPAP data.

---

## Share-sheet import flow

1. In the EMAY iOS app, open the session you want to import and tap **Share** on the CSV export.
2. Pick **Anxiety Watch** in the share sheet.
3. The app dispatches the file off the main actor (a 12-hour overnight is around 36 k rows / 2 MB, large enough to stutter the UI if parsed inline) and presents a modal alert with the inserted/skipped counts and the timestamp range covered.

The app is registered as a `CFBundleDocumentType` for `public.comma-separated-values-text` in `Info.plist`, which is how it shows up in the share sheet for any `.csv` file.

The same dispatcher (`CSVImportRouter`) also accepts CPAP CSV exports — the router sniffs the header line and routes to either the EMAY importer or one of the CPAP importers, so the share-sheet entry point is a single user-visible action.

---

## CSV format

The EMAY SleepO2 CSV is a four-column 1 Hz log:

```
Date,Time,SpO2(%),PR(bpm)
5/8/2026,4:46:58 PM,98,52
5/8/2026,4:46:59 PM,98,52
5/8/2026,4:47:00 PM,97,51
```

The router sniffs the normalized (lower-cased, BOM-stripped) header for two signals: it must start with `date,time,spo2` *and* contain `pr(bpm)` somewhere on the line (see `CSVImportRouter.isEMAYFormat`). This is lenient enough to accept minor EMAY firmware variants (extra trailing columns, different separators around `pr(bpm)`) but strict enough that a CPAP CSV with an unrelated "SpO2" column won't mis-route into the EMAY path and produce confusing "skipped row" diagnostics.

Rows that fail to parse (malformed timestamp, missing field, out-of-range SpO2/PR) are counted in `skippedRowCount` and surfaced in the result alert rather than being silently dropped — so a partially-corrupted file makes its failure mode visible.

---

## Where the data lands

Each accepted row produces up to two `QuantityHealthSample` rows in SwiftData — `EMAYImporter` converts a `0` value to `nil` for both SpO2 and pulse (the device emits `0` when contact is lost), so a row with one zeroed field inserts a single sample and a row with both zeroed inserts none. The string values in the table below are owned by typed constants on `EMAYImporter` (`sourceBundleID`, `sourceName`, `spo2MetricType`, `heartRateMetricType`) — quoted here as their current values, but the importer is the single source of truth:

| Field | SpO2 row | PR row |
|-------|----------|--------|
| `metricType`     | `HKQuantityTypeIdentifierOxygenSaturation` | `HKQuantityTypeIdentifierHeartRate` |
| `sourceBundleID` | `com.emay.SleepO2`                         | `com.emay.SleepO2` |
| `sourceName`     | `EMAY SleepO2`                             | `EMAY SleepO2` |
| `timestamp`      | parsed from the CSV row                    | same as the SpO2 row |
| `value` / `unit` | percent (0–1.0 scaled internally)          | beats per minute |

Choosing the EMAY iOS app's bundle ID as `EMAYImporter.sourceBundleID` is load-bearing: dedup runs on `(sourceBundleID, timestamp, metricType)`, so re-importing the same CSV after the EMAY app has already pushed the night to HealthKit under the matching bundle ID produces zero duplicates. There is one caveat — `EMAYImporter.sourceBundleID` is the mixed-case `com.emay.SleepO2`, while `DeviceProvenance.overnightPulseOximeters` recognizes both `com.emay.SleepO2` and a lowercase `com.emay.sleepo2` variant that HealthKit has been observed to use in some EMAY app versions. Samples written under the lowercase variant will be classified as overnight-oximeter readings by provenance, but won't dedupe against EMAY CSV re-imports — so a lowercase HealthKit push followed by a CSV re-import can leave two rows for the same timestamp. The provenance layer also keys off both variants to classify the readings as "dedicated overnight oximeter" — they aren't downgraded to "wrist sensor, occasional sample" the way an Apple Watch SpO2 reading would be for clinical-stat purposes.

---

## Server sync

Once imported into SwiftData, EMAY samples flow through the existing `QuantityHealthSample` sync path — there's no EMAY-specific server endpoint. On the server side, each sample becomes a row in `quantity_health_samples` with its `source_bundle_id` preserved, and the overnight SpO2 fields on `health_snapshots` (`spo2_nadir_overnight`, `spo2_time_below_90_min`, `spo2_desats_count`) get computed from those samples by `SnapshotAggregator`.

---

## Current status

Shipped:

- Share-sheet entry point for CSV files.
- Strict EMAY header detection in `CSVImportRouter`.
- Per-row parsing with surfaced skip diagnostics.
- Idempotent re-imports via `(sourceBundleID, timestamp, metricType)` dedup.
- Server-side mirror in `quantity_health_samples` and downstream rollup into `health_snapshots`.

---

## Known limits

- **Single-night CSVs only.** EMAY exports cover one recording session per file; multi-night imports are out of scope.
- **Strict-enough header.** A CSV whose header fails both the EMAY sniff (`date,time,spo2` prefix + `pr(bpm)` substring) *and* `CPAPImporter.isCPAPFormat` is rejected with `unrecognizedFormat` — it does not silently fall through to either importer. The router preferring strictness over fuzzy matching is intentional.
- **Timezone.** Timestamps are parsed in the device's current timezone — moving the iPhone between zones between recording and import can shift wall-clock times. This matches HealthKit's behavior for the same data.
- **No graph for raw 1 Hz traces.** Trend charts read from `health_snapshots` daily rollups, not the per-sample table. The detailed 1 Hz waveform is preserved for export but not visualized in-app yet.

---

## Future work

- A waveform view that plots the night's raw SpO2 trace with desaturation markers.
- Optional file-format detection for other consumer oximeters (the dispatcher is structured to grow).
