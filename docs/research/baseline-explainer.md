# How AnxietyWatch calculates your personal baseline

*A clinician-friendly walkthrough of the rolling baseline used in trend charts and PDF reports.*

---

## What is "the baseline"?

When the trends chart shows a dashed horizontal line on your HRV graph, or the report says "AHI elevated vs. baseline," it's referring to a **personal rolling average** — *your* numbers over the recent past, not population norms.

This matters because the same number can be normal for one person and concerning for another. A resting heart rate of 70 bpm is fine for most adults, but for someone whose 30-day average is 55, it's a meaningful 27% elevation.

The baseline is computed for each metric independently:

| Metric | Source |
|---|---|
| HRV (SDNN) | Apple Watch via HealthKit |
| Resting HR | Apple Watch via HealthKit |
| Sleep duration | Apple Watch via HealthKit |
| Respiratory rate | Apple Watch via HealthKit |
| CPAP AHI | ResMed AirSense data |
| SpO₂ nadir (overnight low) | EMAY oximeter or Apple Watch |
| T90 (minutes <90% SpO₂) | EMAY oximeter or Apple Watch |

Each metric has its own baseline because the inputs vary in shape (HRV is roughly log-normal, AHI is bounded at zero, sleep duration is bimodal with weekday/weekend patterns) and you can't apply one statistical model across all of them.

## The four-step calculation

### Step 1: Pick a window

We use the **last 30 days** ending at the moment you view the chart. Older data is excluded — a baseline pulled from data you generated three months ago doesn't reflect your current state. The window size lives in `Constants.baselineWindowDays`.

If you're viewing a chart anchored to a specific past date, the window is the 30 days ending at *that* date, not 30 days ending today. This matters for the SpO₂ and T90 baselines specifically (see `spo2NadirBaseline` and `t90Baseline` in `BaselineCalculator.swift`) — without an upper bound, viewing an older session would mix in newer snapshots and skew the comparison.

### Step 2: Require enough data

If the window has fewer than **14 valid samples**, no baseline is computed. The chart shows the raw data without a reference line.

Why 14? A rolling statistic on a single week of data is too noisy to mean anything clinically. Two weeks gives enough samples that the trimmed mean stabilizes.

This threshold lives in `BaselineCalculator.minimumSampleCount`.

### Step 3: Trim outliers using MAD

Real-world health data has outliers — a 200 bpm heart rate when you sprinted up the stairs, a 30 ms HRV during a panic episode. If we just took the average of every sample, these outliers would pull the baseline toward extremes that aren't representative of "you on a typical day."

We use **median absolute deviation (MAD)** to identify outliers:

1. Compute the median of the window.
2. For each sample, compute `|sample - median|`.
3. The median of those deviations is the MAD.
4. Trim any sample where `|sample - median| > 2.5 × MAD × 1.4826`.

The `1.4826` scaling factor makes MAD roughly equivalent to a standard deviation under a normal distribution — but unlike a standard deviation, MAD is **robust**, meaning a single huge outlier doesn't move it. This is critical because the outliers we want to remove are exactly the things that would warp a standard-deviation-based trimming.

If trimming removes too many samples (more than half), we fall back to the untrimmed set. This handles the case where you have a recent stretch of unusually high or low values that aren't outliers — they're a real trend — and trimming them would hide the change you're trying to see.

### Step 4: Compute mean, standard deviation, and ±N-sigma bounds

From the trimmed values:

- **Mean** — the line drawn on the chart.
- **Standard deviation** — the spread.
- **Lower bound** — `mean - (deviationThreshold × stddev)`. Below this is "unusually low."
- **Upper bound** — `mean + (deviationThreshold × stddev)`. Above this is "unusually high."

For HRV, a value below the lower bound is the clinically meaningful direction (high autonomic load suppresses HRV). For resting HR, the upper bound is what matters (elevated resting HR can indicate stress, illness, or poor sleep recovery). The chart annotation reflects the right direction per metric.

## A worked example

Say you've worn your Apple Watch for the last 45 days, generating one HRV sample per day. The trends chart is about to render a 30-day baseline.

1. **Window**: the most recent 30 of those 45 samples are kept.
2. **Sample count**: 30 ≥ 14, so we proceed.
3. **Median**: 42 ms.
4. **MAD**: 6 ms. After scaling, trim threshold = `2.5 × 6 × 1.4826` = 22.2 ms.
   - Any value below `42 - 22.2 = 19.8` ms or above `42 + 22.2 = 64.2` ms is dropped as an outlier.
   - Most days fall in [25, 60] ms — typical for an adult — so almost all 30 samples survive.
5. **Trimmed mean**: 41 ms. **Stddev**: 7 ms.
   - Lower bound: 41 − (1.5 × 7) = 30.5 ms.
   - Upper bound: 41 + (1.5 × 7) = 51.5 ms.

The chart draws a dashed line at **41 ms** with a shaded band from **30.5 to 51.5 ms**. A new reading at 28 ms shows up below the band — flagged as "lower than your usual."

## What this is not

- **Not a medical diagnosis.** A reading outside the baseline band means "different from your recent average," not "abnormal" in any clinical sense.
- **Not a population norm.** Two people with identical health can have very different baselines because of fitness level, age, medications, or genetics.
- **Not stable forever.** As your underlying health changes (new medication, recovery from illness, training), the baseline shifts to follow. The window slides every day.
- **Not built from a single source.** If you have both Apple Watch and Polar H10 HRV, only the Apple Watch data feeds this baseline today — the Polar values render as a separate overlay because the measurement window is different (~60s sliding vs. per-session overnight aggregate) and mixing them would produce a confused statistic.

## What the report shows

In the clinical PDF report:

- "HRV: 38 ms (baseline 41 ± 7 ms, last 30 days)" — your most recent value, the baseline mean, the spread, and the window.
- A small dot indicator: green if within band, amber if outside band by less than 1 stddev, red if outside by more.

Use the baseline as **context**, not as a verdict. A few days outside the band is usually noise; a sustained shift over 2+ weeks is the signal worth attending to.

---

**Source code:** `AnxietyWatch/Services/BaselineCalculator.swift`
**Tests:** `AnxietyWatchTests/BaselineCalculatorTests.swift`, `BaselineCalculatorCPAPTests.swift`

If you want to turn this into a one-page PDF appendix for the clinical report, dispatch the `process-walkthrough` sub-agent on `BaselineCalculator.swift` and combine the resulting Mermaid diagram with this prose, then render via the `canvas-design` skill.
