#if DEBUG
import SwiftUI

/// Isolated simulator walkthrough of CNS monitoring. It never arms the real
/// coordinator, starts BLE, posts notifications, or persists health events.
struct CNSMonitoringDemoView: View {
    private enum Tier: Int, CaseIterable {
        case clear, watch, confirm, klaxon

        var title: String {
            switch self {
            case .clear: "Clear"
            case .watch: "Watch"
            case .confirm: "Confirm"
            case .klaxon: "Klaxon"
            }
        }
        var color: Color {
            switch self {
            case .clear: .green
            case .watch: .yellow
            case .confirm: .orange
            case .klaxon: .red
            }
        }
        var icon: String {
            switch self {
            case .clear: "checkmark.shield.fill"
            case .watch: "eye.fill"
            case .confirm: "exclamationmark.triangle.fill"
            case .klaxon: "speaker.wave.3.fill"
            }
        }
    }

    @State private var companionPresent = false
    @State private var monitoring = false
    @State private var elapsedMinutes = 0
    @State private var oxygen = 97
    @State private var respiratoryRate = 15
    @State private var heartRate = 68
    @State private var tier: Tier = .clear
    @State private var autoStarted = false
    @State private var isStarting = false

    var body: some View {
        List {
            Section {
                Toggle("Monitor tonight", isOn: .constant(false))
                    .disabled(monitoring)
                Button {
                    beginMonitoring()
                } label: {
                    if isStarting {
                        Label("Starting monitoring…", systemImage: "sensor.tag.radiowaves.forward.fill")
                    } else {
                        Text("Monitor me now")
                    }
                }
                .disabled(monitoring || isStarting)
                Toggle("Companion present", isOn: $companionPresent)
                    .disabled(monitoring)
            } footer: {
                Text("Demo simulation only. No sensor session, alert, or health record is created.")
            }

            Section("Status") {
                HStack {
                    Label(monitoring ? "Monitoring" : "Not monitoring",
                          systemImage: monitoring ? "waveform.path.ecg" : "pause.circle")
                    Spacer()
                    if monitoring {
                        Text("10 min simulated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if monitoring {
                    ProgressView(value: Double(elapsedMinutes), total: 10)
                        .tint(tier.color)
                    LabeledContent("Elapsed", value: "\(elapsedMinutes) of 10 min")
                    LabeledContent("Reporting", value: "EMAY Oximeter, Polar H10")
                    LabeledContent("Active trigger", value: "Ad hoc")
                    LabeledContent("Alert tier") {
                        Label(tier.title, systemImage: tier.icon)
                            .foregroundStyle(tier.color)
                            .fontWeight(.semibold)
                    }
                }
            }

            if monitoring {
                Section("Live signals") {
                    metric("Blood oxygen", value: "\(oxygen)%", icon: "lungs.fill")
                    metric("Respiratory rate", value: "\(respiratoryRate)/min", icon: "wind")
                    metric("Heart rate", value: "\(heartRate) bpm", icon: "heart.fill")
                }

                Section("Alert tier") {
                    HStack(spacing: 12) {
                        Image(systemName: tier.icon)
                            .font(.title2)
                            .foregroundStyle(tier.color)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tier.title).font(.headline)
                            Text(tierMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                if tier == .klaxon {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Highest-tier alert triggered", systemImage: "speaker.wave.3.fill")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text("Wake the person and check breathing. Call emergency services if they are difficult to wake, breathing is slow or stopped, or lips appear blue or gray.")
                            Text("This demo does not provide medical diagnosis and did not send a real notification.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("CNS Monitoring")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if tier == .klaxon {
                klaxonNotification
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-demoCNSSequence"), !autoStarted else { return }
            autoStarted = true
            // Hold on setup controls so the viewer sees the equivalent of
            // choosing “Monitor me now” before the accelerated session begins.
            try? await Task.sleep(for: .seconds(4))
            beginMonitoring()
        }
    }

    private var klaxonNotification: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("CRITICAL CNS ALERT", systemImage: "speaker.wave.3.fill")
                    .font(.headline)
                Spacer()
                Text("now").font(.caption)
            }
            Text("Blood oxygen and breathing have reached the highest alert tier.")
                .font(.subheadline)
            Text("Wake the person and check breathing. Call emergency services if they are difficult to wake or breathing is slow or stopped.")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.red.gradient, in: .rect(cornerRadius: 16))
        .shadow(radius: 12)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().fontWeight(.semibold)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private var tierMessage: String {
        switch tier {
        case .clear: "Signals are near the starting range."
        case .watch: "A downward trend needs closer observation."
        case .confirm: "Multiple signals confirm a concerning decline."
        case .klaxon: "Critical sustained decline; urgent response indicated."
        }
    }

    private func beginMonitoring() {
        guard !monitoring, !isStarting else { return }
        isStarting = true
        Task { @MainActor in
            // Briefly expose acknowledgement of the visible button action.
            try? await Task.sleep(for: .milliseconds(650))
            isStarting = false
            startSimulation()
        }
    }

    private func startSimulation() {
        guard !monitoring else { return }
        monitoring = true
        Task { @MainActor in
            // Ten simulated minutes in roughly fifteen seconds. Values and
            // tiers are deterministic and clearly labeled as simulation.
            let oxygenValues = [97, 97, 96, 95, 94, 93, 91, 89, 86, 83, 80]
            let respirationValues = [15, 15, 14, 14, 13, 12, 11, 10, 9, 8, 7]
            let heartValues = [68, 67, 66, 65, 64, 62, 60, 57, 54, 50, 46]
            for minute in 0...10 {
                elapsedMinutes = minute
                oxygen = oxygenValues[minute]
                respiratoryRate = respirationValues[minute]
                heartRate = heartValues[minute]
                tier = minute < 4 ? .clear : minute < 7 ? .watch : minute < 9 ? .confirm : .klaxon
                if minute < 10 { try? await Task.sleep(for: .milliseconds(1500)) }
            }
            // Hold the highest-tier notification for the recording viewer.
            try? await Task.sleep(for: .seconds(7))
        }
    }
}
#endif
