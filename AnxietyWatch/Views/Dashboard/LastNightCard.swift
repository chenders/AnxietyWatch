import SwiftUI

/// Hero overnight summary. Merges sleep (with efficiency/WASO), CPAP (AHI +
/// usage), and overnight SpO₂ (nadir + t<90 + desats) into one tappable card.
/// Headline is composed via `LastNightHeadline.compose(...)`.
///
/// Pass `wrappedInLink: true` when the card is used as the label of a
/// `NavigationLink`. This switches the card to `.accessibilityElement(children: .ignore)`
/// so that VoiceOver treats the whole card as one interactive element. The
/// `.accessibilityLabel` and `.accessibilityHint` must be applied to the
/// `NavigationLink` at the call site.
struct LastNightCard: View {
    let snapshot: HealthSnapshot
    let sleepEvents: [SleepStageEvent]
    let lastCPAP: CPAPSession?
    let cpapAHIBaseline: BaselineCalculator.BaselineResult?
    /// Set to `true` when the card is the label of a `NavigationLink`.
    /// Suppresses children so the link element owns the combined label.
    var wrappedInLink: Bool = false

    var body: some View {
        let efficiency = SleepEfficiencyCalculator.compute(from: sleepEvents)
        let headline = LastNightHeadline.compose(
            efficiencyPct: efficiency.efficiencyPct,
            efficiencyEstimated: efficiency.isBedTimeEstimated,
            ahi: lastCPAP?.ahi,
            nadirPct: snapshot.spo2NadirOvernight
        )

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last Night").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(DashboardViewModel.nightFreshnessLabel(for: snapshot.date))
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Text(headline.text)
                .font(.subheadline.bold())

            Divider()

            // Sleep row — prefix in-bed value with "~" when the duration is
            // estimated (no inBed events; asleep span used as denominator).
            let inBedPrefix = efficiency.isBedTimeEstimated ? "~" : ""
            row(label: "Sleep",
                value: "\(inBedPrefix)\(efficiency.inBedMinutes / 60)h \(efficiency.inBedMinutes % 60)m in bed" +
                       " · \(efficiency.asleepMinutes / 60)h \(efficiency.asleepMinutes % 60)m asleep" +
                       " · WASO \(efficiency.wasoMinutes)m")

            // Stages row
            HStack {
                Text("Stages").font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                SleepStagesView(
                    deep: snapshot.sleepDeepMin ?? 0,
                    rem: snapshot.sleepREMMin ?? 0,
                    core: snapshot.sleepCoreMin ?? 0,
                    awake: snapshot.sleepAwakeMin ?? 0
                )
                .frame(height: 14)
            }

            // CPAP row
            if let cpap = lastCPAP {
                // Unknown AHI (EDF-only night, F-094) → "AHI —" and no baseline
                // delta; usage still shows. Never fabricate a 0.0 or a delta
                // against an absent value.
                let ahiText = cpap.ahi.map { String(format: "AHI %.1f", $0) } ?? "AHI —"
                let deltaText: String = {
                    guard let ahi = cpap.ahi, let b = cpapAHIBaseline else { return "" }
                    return String(format: " · %+.1f vs baseline", ahi - b.mean)
                }()
                row(label: "CPAP",
                    value: String(format: "%@ · %dh %dm used%@",
                                  ahiText,
                                  cpap.totalUsageMinutes / 60,
                                  cpap.totalUsageMinutes % 60,
                                  deltaText))
            }

            // SpO₂ row
            if let nadir = snapshot.spo2NadirOvernight {
                let parts: [String?] = [
                    "Nadir \(Int(nadir.rounded()))%",
                    snapshot.spo2TimeBelow90Min.map { "\($0)m <90%" },
                    snapshot.spo2DesatsCount.map { "\($0) desats" }
                ]
                let nonNil = parts.compactMap { $0 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("SpO₂").font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text(nonNil.joined(separator: " · ")).font(.caption)
                        Spacer()
                    }
                    // Disclose mixed provenance (F-092): when the nadir/avg and
                    // the T90/desats were computed from different source
                    // populations, say which — otherwise a brief-oximeter nadir
                    // reads as describing the same night as an all-Watch T90.
                    if snapshot.spo2SourcesDiverge,
                       let agg = snapshot.spo2AggregateBasis,
                       let burden = snapshot.spo2BurdenBasis {
                        Text("Nadir: \(agg.label) · T90/desats: \(burden.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        // When wrapped in a NavigationLink, suppress children so VoiceOver
        // treats the link as a single element. The link at the call site owns
        // the label. When standalone, combine children for a clean read-out.
        .accessibilityElement(children: wrappedInLink ? .ignore : .combine)
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value).font(.caption)
            Spacer()
        }
    }
}
