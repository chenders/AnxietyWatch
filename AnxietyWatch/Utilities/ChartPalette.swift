import SwiftUI

/// Centralized color tokens for AnxietyWatch's chart suite.
///
/// Before this enum existed, each `Views/Trends/*Chart.swift` hardcoded its
/// own `Color` literals — `.red` for HealthKit HR in one file, `.red` for
/// severity bands in another, `.blue` for both Polar HR and Core sleep. Same
/// color, different meanings, depending on which chart you were looking at.
///
/// Every chart series now reads its color from a named token here. The token
/// names are semantic ("source of HR data") rather than visual ("red"), so
/// changing a hue in one place updates every chart consistently.
///
/// The severity scale (`Color.severity(_:)` in `SeverityColor.swift`) is
/// orthogonal — it encodes the user's anxiety level, not a data source — and
/// is left alone. Tokens here that overlap with severity bands (e.g.
/// `outOfRangeFill` is reddish) avoid the exact severity hue so a "high
/// anxiety" mark and a "value out of normal range" overlay don't look
/// identical when both fire on the same chart.
enum ChartPalette {

    // MARK: - Heart rate sources

    /// HealthKit (Apple Watch / iPhone) heart rate. Red is inherited Apple
    /// Watch convention; preserved for muscle-memory continuity.
    static let hkHeartRate = Color.red

    /// Polar H10 chest-strap heart rate. Distinct from HK HR so charts that
    /// show both sources side-by-side are unambiguous.
    static let polarHeartRate = Color.blue

    // MARK: - HRV sources and derived metrics

    /// HealthKit-derived HRV (SDNN). Shares Polar HR's blue hue because the
    /// two never co-occur on the same chart (HK HRV lives on HRVTrendChart,
    /// Polar HR lives on HeartRateTrendChart). On the Trends scroll they
    /// appear sequentially; a future palette pass may want to differentiate
    /// them to remove the soft cross-chart collision.
    static let healthKitHRV = Color.blue

    /// Polar H10 RMSSD — the parasympathetic-tone metric. Purple separates it
    /// visually from HR (red/blue) on charts that overlay both.
    static let polarRMSSD = Color.purple

    /// Polar H10 HF power (parasympathetic-tone proxy). Used both for the
    /// per-night mean trend chart and the within-session detail view. Teal
    /// was chosen during the biofeedback phase to pair distinctively with LF
    /// indigo; before this enum existed the trend chart used purple, so the
    /// trend chart now picks up a visual shift in exchange for cross-view
    /// consistency.
    static let polarHFPower = Color.teal

    /// Polar H10 LF power (sympathetic-tone proxy). Paired with HF teal in
    /// the session detail view. A deep navy (not the system `.indigo` —
    /// that's reserved for `sleepDeep`) so it doesn't collide with sleep
    /// stages when both charts appear in the Trends scroll.
    static let polarLFPower = Color(red: 0.20, green: 0.20, blue: 0.55)

    /// Polar H10 LF/HF ratio (sympathovagal balance).
    static let polarLFHFRatio = Color.orange

    // MARK: - Sleep stages

    /// Deep sleep stage. Indigo is darker than core sleep blue so the legend
    /// reads as a depth gradient.
    static let sleepDeep = Color.indigo

    /// REM sleep stage.
    static let sleepREM = Color.cyan

    /// Core (light) sleep stage. Muted to recede behind deep/REM bands.
    static let sleepCore = Color.blue.opacity(0.5)

    // MARK: - SpO2 sources

    /// EMAY oximeter SpO2 readings (highest fidelity).
    static let oximeterSpO2 = Color.green

    /// Apple Watch SpO2 readings (HealthKit fallback). Amber signals "less
    /// authoritative" without implying alarm.
    static let appleWatchSpO2 = Color.orange

    /// EMAY oximeter pulse rate (live-session per-minute series). A
    /// heart-family hue deliberately distinct from `hkHeartRate` red and
    /// `polarHeartRate` blue so a live pulse trace can't be misread as
    /// either of those sources; pink also pairs with the same-card
    /// `oximeterSpO2` green without colliding with `glucose` (a deeper,
    /// redder magenta on a different card).
    static let oximeterPulse = Color.pink

    // MARK: - Other physiological series

    /// CPAP nightly usage hours bar. Despite living in the file named
    /// `SleepRespiratoryTrendChart.swift`, this color is consumed by the
    /// CPAP usage bars at the bottom of that chart stack — not by a
    /// respiratory rate series (the file currently has no RR series). Slate
    /// blue is environmental/equipment context and recedes behind the SpO2
    /// and T90 marks above it.
    static let cpapUsage = Color(red: 0.30, green: 0.45, blue: 0.60)

    /// Continuous glucose monitoring. A true magenta (NOT `Color.purple`,
    /// which `polarRMSSD` already owns) — the comment always claimed the
    /// "magenta family" but the token was literally `.purple`, colliding with
    /// the HRV RMSSD series (F-049). Distinct redder/pinker hue keeps a
    /// multi-metric overlay legible.
    static let glucose = Color(red: 0.85, green: 0.12, blue: 0.55)

    /// Activity (active energy / move ring).
    static let activity = Color.orange

    /// Barometric pressure trend. Slate-gray — atmospheric data is environmental
    /// context, not physiological signal, so it visually recedes.
    static let barometric = Color.gray

    // MARK: - Correlation / cross-metric overlays

    /// Scatter-plot dots in `CorrelationChartView` (signal vs. anxiety
    /// severity). Generic blue with low opacity so cluster density reads
    /// without any one dot dominating; signal-specific color would be
    /// misleading because the same view renders many different signals.
    static let correlation = Color.blue.opacity(0.6)

    // MARK: - Annotation layers (universal across charts)

    /// Personal-baseline reference line. Subtle, dashed in chart code; this
    /// token sets the stroke color. Green-with-opacity reads as a "healthy
    /// average" cue without overpowering the data marks above it. The
    /// 0.6 opacity makes it visually distinct from `oximeterSpO2` (full
    /// green) when both appear on the same chart stack.
    static let baselineRule = Color.green.opacity(0.6)

    /// Baseline label background pill behind the baseline line value.
    static let baselineLabel = Color.green

    /// Fill for chart regions where the value is out of normal range. Used as
    /// an overlay; opacity ensures it doesn't overpower the data marks.
    static let outOfRangeFill = Color.red.opacity(0.3)

    /// Fill for chart regions where the value is in normal range.
    static let inRangeFill = Color.green.opacity(0.15)

    // MARK: - Severity-band shorthand
    //
    // Charts that need to render the same severity bands as
    // `Color.severity(_:)` should call that function directly — it lives in
    // `SeverityColor.swift` and is the source of truth for severity scale.
    // No alias is provided here on purpose: severity is orthogonal to
    // chart-source palette, and a single-source-of-truth call site avoids
    // accidental drift between the two namespaces.
}
