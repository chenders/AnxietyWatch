import SwiftUI

/// User-facing explainer for the LF/HF HRV chart. Two registers: a plain
/// summary first, a clinical detail section second. Lets the reader pick
/// their depth rather than aggressively progressively-disclosing one or
/// the other, which the UX lens flagged as patronizing.
struct LFHFExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(title: "At a glance") {
                        Text(
                            "Your heart rate varies slightly from beat to beat. " +
                            "**HF power** picks up the breathing-driven variability " +
                            "that tracks your body's calm-and-recover system. " +
                            "**LF power** mixes several signals together — useful " +
                            "for relative trends but not a clean readout of any one thing."
                        )
                    }

                    section(title: "Clinical detail") {
                        Text(
                            "HF (0.15–0.40 Hz) reflects parasympathetic / vagal activity. " +
                            "Higher tends to mean better recovery and lower physiological arousal."
                        )
                        Text(
                            "LF (0.04–0.15 Hz) is *not* a clean sympathetic readout despite " +
                            "older interpretations. It combines baroreflex activity, breathing " +
                            "patterns, and partial sympathetic input."
                        )
                        Text(
                            "The **LF/HF ratio** is useful for tracking shifts in your own pattern " +
                            "over time but should not be read as an absolute \"sympathetic dominance\" " +
                            "score. All frequency-domain measures are influenced by breathing rate, " +
                            "so values are most comparable within similar conditions (e.g., " +
                            "night-to-night during sleep)."
                        )
                    }

                    section(title: "Reference") {
                        Text(
                            "Shaffer F, Ginsberg JP. An Overview of Heart Rate " +
                            "Variability Metrics and Norms. Front Public Health. " +
                            "2017;5:258. doi:10.3389/fpubh.2017.00258"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("About LF/HF HRV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .font(.body)
        }
    }
}

#if DEBUG
#Preview {
    LFHFExplainerSheet()
}
#endif
