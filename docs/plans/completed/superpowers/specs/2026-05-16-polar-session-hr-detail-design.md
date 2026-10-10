# Polar Session HR Detail View — Design

**Date:** 2026-05-16
**Status:** Draft — pending implementation plan

## Problem

The Trends → Resting Heart Rate card shows Polar overnight data as a single blue diamond per night (a duration-weighted mean of `SensorSession.summaryJSON.hrMean`). The diamond is correct for between-night comparison against HealthKit's daily resting HR, but it discards intra-night structure that the strap actually captured: HR dips in deep sleep, rises in REM, brief arousals, and excursions correlated with anxiety events.

The raw per-RR-interval data already exists on disk (`RRArchiveWriter` writes ~300 KB/night to `applicationSupportDirectory/rr_archives/<sessionID>.rr`), but no on-device view currently consumes it. This design adds one.

## Non-goals

- No schema change. We do not persist per-minute HR rows; we derive them on demand from the existing `.rr` archives.
- No change to the trends card aggregation. The blue diamond stays — this view is the detail path *behind* it.
- No new sync surface. The `.rr` archive upload path is unchanged.
- No HR-spike awakening detection (heuristic risks misleading clinical-looking numbers).
- No HRV overlay on this view. HRV detail already lives in `LFHFSessionDetailView`.
- No per-beat / instantaneous HR rendering — would push Swift Charts past its comfort zone on iOS 26 and produce a fuzzy band, not a usable line.

## User-visible behavior

User taps the blue diamond on `HeartRateTrendChart` → pushes a new screen titled by the night anchor date (e.g. "Night of May 11"). The screen shows:

- **Header** with the session window (e.g. "11:42 PM – 7:18 AM · 7h 36m wear · 2 sessions") so it's honest about BLE fragmentation.
- **Stat row**: Mean BPM · Min BPM · Max BPM · Awakenings. Min/Max are computed from the per-minute aggregated series, not raw RR (single-beat extrema are noise). Awakenings is the count of HK `SleepAnalysis` `.awake` intervals inside the session window; renders as `—` when HK data is absent.
- **Chart**: one `LineMark` of per-minute mean HR (red) over the session's authoritative time span. Background bands shaded per HK sleep stage (deep / core / REM / awake) when HK data is available. Vertical `RuleMark`s for any anxiety entries whose `timestamp` falls inside the session window, colored by severity (matches `HeartRateTrendChart` convention).
- **Caption under chart title**: `"No sleep stages for this night"` shown only when HK sleep data is absent for the window. The bands disappear; the HR line and rules still render.

The diamond is the **only** entry point. We are deliberately not adding rows to `LFHFSessionsListView` or sections to `LFHFSessionDetailView` — keeping this view in one navigation slot makes it easy to remove or restyle later if usage data says it isn't pulling weight.

## Architecture

### New files

**`AnxietyWatch/Views/Trends/PolarSessionHRDetailView.swift`**

```swift
/// Carries everything the detail view needs to render without re-deriving
/// from raw SensorSession rows. Passed through navigation by value so the
/// destination is fully self-describing and re-entrant.
struct CoalescedNightRef: Hashable, Codable {
    let id: UUID                       // == first member SensorSession.id, per LFHFAggregator.CoalescedNight
    let startTime: Date
    let endTime: Date
    let memberSessionIDs: [UUID]
}

struct PolarSessionHRDetailView: View, Equatable {
    let night: CoalescedNightRef       // identity prop

    var body: some View { ... }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.night == rhs.night
    }
}
```

Conforms to `Equatable` on identity props only and is wrapped with `.equatable()` at the `.navigationDestination` call site (CLAUDE.md "Closure-based NavigationLink destinations that contain @Query" pitfall). The view uses `@Query` to fetch `AnxietyEntry` rows for the window; without `.equatable()` every parent-body rerender re-pushes the destination on iOS 26.

Passing the full `CoalescedNightRef` (not just the UUID) avoids re-running `LFHFAggregator.coalesce` inside the destination just to look up its own member set and time bounds. The `SensorSession` `@Query` then uses a single-clause `memberSessionIDs.contains($0.id)` predicate, which `#Predicate` lowers to an `IN` clause — safe per the CLAUDE.md "compound predicate hang" guidance (single-clause, no captured non-primitive AND-chain).

The body composes:
- A header card (session window + stat row).
- A loading state (`ProgressView` inside the chart card) while the .rr archives parse.
- The chart card, which shadows the trends chart styling (`ChartCard`-equivalent or direct dark card) and contains the `LineMark` + `RectMark` stage bands + `RuleMark` anxiety entries.

**`AnxietyWatch/Services/RRArchiveAggregator.swift`** — pure helpers, no view code, no SwiftData dependency.

```swift
enum RRArchiveAggregator {
    /// One point in the per-minute HR series. `nil` bpm marks a gap
    /// (either BLE was disconnected, or the minute had no in-range RR).
    struct HRMinutePoint: Identifiable, Equatable, Sendable {
        let id: UUID            // deterministic from timestamp for chart stability
        let timestamp: Date
        let bpm: Double?
    }

    /// Read each .rr archive, bucket into per-minute means using
    /// `60_000 / mean(rr in bucket)`, return a chronologically-sorted
    /// series spanning `window`. Gaps (no in-range RR for a bucket)
    /// emit `nil` so Swift Charts renders a line break.
    static func perMinuteHR(
        rrFiles: [URL],
        window: ClosedRange<Date>
    ) -> [HRMinutePoint]

    /// Count of HK SleepAnalysis `.awake` intervals (typed as the
    /// app's existing sleep stage struct) that intersect `window`.
    static func awakeIntervalCount(
        hkSleepIntervals: [HKSleepInterval],
        in window: ClosedRange<Date>
    ) -> Int
}
```

The `HRMinutePoint.id` is derived deterministically from `timestamp` (e.g., `UUID(uuidString: deterministicHash)`) so SwiftUI Charts doesn't re-animate every render.

**`AnxietyWatchTests/RRArchiveAggregatorTests.swift`** — Swift Testing (`@Test`, `#expect`). Coverage cases in §Testing below.

### Modified files

**`AnxietyWatch/Views/Trends/HeartRateTrendChart.swift`** — the chart gains tap regions over its Polar diamonds. Swift Charts marks aren't directly tappable, so we use the standard `.chartOverlay { proxy in GeometryReader { geo in … } }` pattern: place an invisible `Rectangle().contentShape(…).onTapGesture { … }` that uses `proxy.value(atX:)` to find which `CoalescedNightRef` the tap is closest to, then sets a `@State var tappedNight: CoalescedNightRef?` which a programmatic `NavigationLink(value: tappedNight) { EmptyView() }` (or `navigationDestination(item:)` on iOS 17+) consumes. The chart's input now needs `[CoalescedNightRef]` alongside `[NightlyValue]` so the overlay can resolve x-position back to a navigable identity. The chart's visible output is unchanged.

Exact tap-hit-test code is a known SwiftUI Charts pattern; the precise form is left to implementation. The design constraint is: tapping anywhere within ±0.4 day of a diamond x-position selects that night.

**`AnxietyWatch/Views/Trends/TrendsView.swift`** — register `.navigationDestination(for: CoalescedNightRef.self) { ref in PolarSessionHRDetailView(night: ref).equatable() }` on the existing `NavigationStack`. Pass the `[CoalescedNightRef]` for the window to `HeartRateTrendChart` so it can build its tap regions.

### Data flow

1. User taps diamond → the full `CoalescedNightRef` (identity + time bounds + member session IDs) is pushed onto the nav stack.
2. `PolarSessionHRDetailView` resolves member sessions via a single-clause `@Query`: `#Predicate<SensorSession> { night.memberSessionIDs.contains($0.id) }` (`IN`-style lookup, safe per the compound-predicate-hang guidance).
3. View also `@Query`s `AnxietyEntry` rows whose `timestamp` falls in `[night.startTime, night.endTime]`.
4. View asks HealthKit for sleep samples in `[night.startTime − 30 min, night.endTime + 30 min]` to catch lying-down-before-falling-asleep edges. Uses the existing `HealthKitManager` actor; adds a thin helper method if one doesn't already exist.
5. View kicks off a `Task` that calls `RRArchiveAggregator.perMinuteHR(rrFiles:window:)` off-main, passing `[RRArchiveWriter.archiveURL(for: $0)]` for each member session ID. While that's running, the chart card shows `ProgressView`.
6. When the task returns, the chart renders. The HR line uses a single `LineMark` series; gap minutes (`bpm == nil`) produce line breaks (the documented Swift Charts gap-drawing pattern).

### x-axis anchor (CLAUDE.md authoritative-timestamps rule)

The chart's `chartXScale(domain:)` is `[coalescedNight.startTime ... coalescedNight.endTime]` — the **authoritative** timestamps from `SensorSession`, NOT the min/max of `.rr` archive timestamps. The first RR sample in a session can lag the session start by up to ~60 s, which would visually clip the start by a minute on near-midnight sessions.

### Off-axis NaN avoidance (CLAUDE.md iOS-26 chart pitfall)

The chart does **not** use `chartYScale(domain:)` paired with `.nan` y-values (the documented iOS 26 layout pathology). Gaps are represented by `nil` and rendered with the standard `LineMark` nil-handling. The y-axis auto-scales to the data; we pre-clip impossible BPM values (`< 30` or `> 220` — beyond physiological range) at the aggregator layer so a freak RR outlier can't drive the y-axis to absurd values.

## State and edge cases

| Condition | Behavior |
|---|---|
| All members' `.rr` files missing | `ContentUnavailableView("No raw HR archive for this session", systemImage: "waveform.path.ecg")`. Rare — only legacy orphan-recovered sessions. |
| Some members' `.rr` files missing/corrupt | Skip those members, render the rest. Log via `os.Logger`. If all fail → same as above. |
| HK sleep stages missing for the window | Hide background bands; show `"No sleep stages for this night"` caption under the card title. HR line + anxiety rules still render. Awakenings stat shows `—`. |
| Anxiety entries empty in window | No vertical rules. No special copy. |
| Single member with BLE gaps | Per-minute bucket with no in-range RR → `nil` bpm → line break at that minute. |
| Multi-member coalesced night | All members' RR data is concatenated chronologically before bucketing. Gaps between members' wear intervals naturally produce `nil` minutes. |
| Member session is still in-progress (`endTime == nil`) | Won't reach this view — `LFHFAggregator.coalesce` already filters non-finalized sessions, so the diamond doesn't exist for in-progress sessions. |
| Per-minute bucket has only out-of-range RR (artifact filter rejects all) | `nil` bpm → line break. |

## Testing

Pure-helper tests on `RRArchiveAggregator`:

1. **Single-member happy path**: a fixture `.rr` file with 60 minutes of synthetic RR at constant 60 BPM → `perMinuteHR` returns 60 points, each with `bpm ≈ 60.0` (`abs(bpm - 60.0) < 0.001` per CLAUDE.md float-equality rule).
2. **Multi-member with 5-min gap**: two fixture files representing a BLE drop+reconnect; expected output has `nil`s in the 5 gap minutes and correct means on either side.
3. **All-zero / out-of-range RR**: a bucket containing only RR values outside `[250, 2000] ms` → `nil` bpm.
4. **Missing file**: passing a URL that doesn't exist → that URL contributes nothing; no throw.
5. **Awakening count**: HK samples with two `.awake` intervals inside the window, one outside → returns 2; with no `.awake` samples → returns 0.
6. **Window clamping**: RR timestamps outside the requested window are dropped, even if present in the file.
7. **Pre-clip extremes**: a bucket whose mean would yield BPM > 220 or < 30 → `nil` (treat as artifact, not data).
8. **Deterministic point IDs**: same input file → same `HRMinutePoint.id` sequence across runs (chart-stability invariant).

A single smoke test on `PolarSessionHRDetailView` that constructs it with an empty `nightID` and verifies the body type-checks. Visual correctness is validated by running on the simulator with a real overnight session.

## Performance notes

- `.rr` archive size: ~300 KB/night for typical 7–8 h sessions. Read is one `Data(contentsOf:)` + a record loop; <100 ms on modern devices. Off-main via `Task`.
- Per-minute bucketing is O(n) over RR records. For a typical 30k-record night, well under 10 ms.
- The chart renders ~450 marks for a 7.5 h session, well below the density threshold where iOS 26 Charts starts struggling.
- No caching layer is needed: the view is short-lived (one push), the parse cost is small, and adding a cache invites stale-state bugs when archives are appended to during BLE reconnects.

## Sequencing

This spec covers one cohesive change. The implementation plan should sequence it as:

1. `RRArchiveAggregator` + tests (pure, no UI dependency — lands first, fully verified).
2. `PolarSessionHRDetailView` with mock data wiring (UI lands second, visible in previews even before nav is wired).
3. `HeartRateTrendChart` tap region + `TrendsView` `navigationDestination` registration (last — connects the existing chart to the new view).

Each step is independently mergeable; CI green at every step.

## Open questions

None at design time. Decisions captured in this spec:

- Entry point: tap blue diamond only (not list view, not session detail). ✅
- Layout: HR line + HK sleep stages + anxiety rules (option C). ✅
- HR resolution: per-minute mean. ✅
- Awakenings: HK `.awake` interval count, `—` when HK missing. ✅
- Sleep-stage fallback: graceful (hide bands, keep chart). ✅
