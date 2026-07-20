#if DEBUG
import SwiftUI
import OSLog

/// DEBUG-only in-app self-test: replays a desaturation through the REAL
/// `CNSDetectionPipeline` and shows the tier the engine computes, live, with
/// full debug detail (per-signal severity/confidence, assessment state, and a
/// tier-transition log). Runs entirely in memory (see `CNSKlaxonSelfTest`) — no
/// CoreBluetooth, no SwiftData writes, no notifications — so it never touches
/// real health records. Progress is also emitted to `os_log`
/// (subsystem `com.anxietywatch.app`, category `CNSSelfTest`) for the device
/// console.
struct CNSDetectionSelfTestView: View {
    private let log = Logger(subsystem: "com.anxietywatch.app", category: "CNSSelfTest")

    @State private var steps: [CNSKlaxonSelfTest.Step] = []
    @State private var transitions: [CNSKlaxonSelfTest.Transition] = []
    @State private var index = 0
    @State private var running = false
    @State private var maxTier: CNSAlertTier = .clear

    @State private var playbackTask: Task<Void, Never>?

    private var current: CNSKlaxonSelfTest.Step? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    private var firstKlaxonSecond: Int? {
        steps.first { $0.tier == .klaxon }?.second
    }

    var body: some View {
        List {
            liveDongleSection
            controlSection
            if let step = current {
                engineSection(step)
                contributionsSection(step)
                vitalsSection(step)
                transitionsSection
                resultSection
            }
        }
        .navigationTitle("Klaxon Self-Test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { playbackTask?.cancel() }
    }

    // MARK: - Sections

    private var liveDongleSection: some View {
        Section {
            NavigationLink {
                CNSLiveDongleSelfTestView()
            } label: {
                Label("Run with live dongle (real BLE)", systemImage: "dot.radiowaves.left.and.right")
            }
        } header: {
            Text("Live")
        } footer: {
            Text("Uses the EMAY dongle over real Bluetooth through the real coordinator — in-memory only, "
                + "nothing written. The synthetic run below needs no hardware.")
        }
    }

    private var controlSection: some View {
        Section {
            Button {
                run()
            } label: {
                Label(running ? "Running…" : "Run detection self-test",
                      systemImage: running ? "waveform.path.ecg" : "play.fill")
            }
            .disabled(running)
        } footer: {
            Text("Feeds a scripted desaturation into the real CNS detection engine and shows the tier it "
                + "computes. In-memory only — no health records, monitoring sessions, Bluetooth, or "
                + "notifications are created. Not sensor data.")
        }
    }

    private func engineSection(_ step: CNSKlaxonSelfTest.Step) -> some View {
        Section("Engine output") {
            tierRow(step.tier)
            LabeledContent("Virtual time", value: "\(step.second)s")
            LabeledContent("State", value: step.stateLabel)
            LabeledContent("Can assess", value: step.canAssess ? "Yes" : "Not yet")
            LabeledContent("Risk score", value: step.riskScore.map { String(format: "%.2f", $0) } ?? "—")
        }
    }

    private func contributionsSection(_ step: CNSKlaxonSelfTest.Step) -> some View {
        Section("Signal contributions") {
            if step.contributions.isEmpty {
                Text("No per-signal contributions this second (state: \(step.stateLabel)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(step.contributions.enumerated()), id: \.offset) { _, contribution in
                    LabeledContent {
                        Text("sev \(String(format: "%.2f", contribution.severity))"
                            + " · conf \(String(format: "%.2f", contribution.confidence))")
                            .monospacedDigit()
                    } label: {
                        Text("\(kindLabel(contribution.kind)) · \(sourceLabel(contribution.source))")
                    }
                }
            }
        }
    }

    private func vitalsSection(_ step: CNSKlaxonSelfTest.Step) -> some View {
        Section("Fed vitals (from scenario, not a sensor)") {
            LabeledContent("SpO₂", value: "\(step.spo2)%")
            LabeledContent("Pulse", value: "\(step.pulse) bpm")
        }
    }

    private var transitionsSection: some View {
        Section("Tier transitions") {
            if transitions.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(transitions.enumerated()), id: \.offset) { _, transition in
                    LabeledContent {
                        Text("\(transition.second)s").monospacedDigit()
                    } label: {
                        Label("\(tierTitle(transition.from)) → \(tierTitle(transition.to))",
                              systemImage: tierIcon(transition.to))
                            .foregroundStyle(tierColor(transition.to))
                    }
                }
            }
        }
    }

    private var resultSection: some View {
        Section("Result") {
            LabeledContent("Highest tier reached") {
                Label(tierTitle(maxTier), systemImage: tierIcon(maxTier))
                    .foregroundStyle(tierColor(maxTier))
                    .fontWeight(.semibold)
            }
            if maxTier == .klaxon {
                Label("KLAXON fired\(firstKlaxonSecond.map { " at \($0)s" } ?? "") — the engine escalated.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if !running && !steps.isEmpty {
                Label("Klaxon not reached (max: \(tierTitle(maxTier))).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func tierRow(_ tier: CNSAlertTier) -> some View {
        HStack(spacing: 12) {
            Image(systemName: tierIcon(tier))
                .font(.title2)
                .foregroundStyle(tierColor(tier))
            VStack(alignment: .leading, spacing: 2) {
                Text(tierTitle(tier)).font(.headline)
                Text("engine-computed tier").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Run

    /// Detection runs synchronously up front (pure + fast); the UI then plays
    /// the pre-computed verdicts back so the escalation is watchable. Also
    /// emits the summary + transition log to `os_log`.
    private func run() {
        playbackTask?.cancel()
        let computed = CNSKlaxonSelfTest.run()
        let changes = CNSKlaxonSelfTest.transitions(in: computed)
        steps = computed
        transitions = changes
        index = 0
        maxTier = .clear
        running = true

        log.debug("Self-test: \(computed.count) steps, \(changes.count) tier transitions")
        for change in changes {
            log.debug("tier \(tierTitle(change.from)) → \(tierTitle(change.to)) at \(change.second)s")
        }
        if let klaxon = computed.first(where: { $0.tier == .klaxon }) {
            log.debug("KLAXON reached at \(klaxon.second)s (SpO2 \(klaxon.spo2)%, pulse \(klaxon.pulse))")
        } else {
            log.error("Self-test did NOT reach klaxon — engine may have regressed")
        }

        playbackTask = Task { @MainActor in
            for i in computed.indices {
                if Task.isCancelled { break }
                index = i
                if computed[i].tier.rawValue > maxTier.rawValue { maxTier = computed[i].tier }
                try? await Task.sleep(for: .milliseconds(25))
            }
            running = false
        }
    }

    // MARK: - Labels

    private func tierTitle(_ tier: CNSAlertTier) -> String {
        switch tier {
        case .clear: "Clear"
        case .watch: "Watch"
        case .confirm: "Confirm"
        case .klaxon: "Klaxon"
        }
    }

    private func tierIcon(_ tier: CNSAlertTier) -> String {
        switch tier {
        case .clear: "checkmark.shield.fill"
        case .watch: "eye.fill"
        case .confirm: "exclamationmark.triangle.fill"
        case .klaxon: "speaker.wave.3.fill"
        }
    }

    private func tierColor(_ tier: CNSAlertTier) -> Color {
        switch tier {
        case .clear: .green
        case .watch: .yellow
        case .confirm: .orange
        case .klaxon: .red
        }
    }

    private func kindLabel(_ kind: CNSSignalKind) -> String {
        switch kind {
        case .spo2: "SpO₂"
        case .respiratoryRate: "Resp rate"
        case .heartRate: "Heart rate"
        case .hrv: "HRV"
        }
    }

    private func sourceLabel(_ source: CNSSignalSource) -> String {
        switch source {
        case .emayOximeter: "EMAY"
        case .polarH10: "Polar H10"
        case .appleWatch: "Apple Watch"
        case .as11Bridge: "AS11"
        }
    }
}
#endif
