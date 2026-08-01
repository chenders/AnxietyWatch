#if DEBUG
import SwiftUI

/// Isolated, accelerated walkthrough of CNS monitoring. It never arms the
/// production coordinator, starts BLE, posts notifications, or persists data.
/// The deterministic sequence is intended for simulator video capture.
struct CNSMonitoringDemoView: View {
    private enum Tier: Int {
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

    private struct Frame {
        let simulatedMinute: Int
        let oxygen: Int
        let respiratoryRate: Int
        let heartRate: Int
        let rmssd: Int
        let watchHeartRate: Int
        let risk: Int
        let tier: Tier
    }

    private let frames = [
        Frame(simulatedMinute: 0, oxygen: 98, respiratoryRate: 15, heartRate: 68, rmssd: 46, watchHeartRate: 69, risk: 6, tier: .clear),
        Frame(simulatedMinute: 1, oxygen: 97, respiratoryRate: 15, heartRate: 67, rmssd: 44, watchHeartRate: 68, risk: 9, tier: .clear),
        Frame(simulatedMinute: 2, oxygen: 96, respiratoryRate: 14, heartRate: 65, rmssd: 39, watchHeartRate: 66, risk: 18, tier: .clear),
        Frame(simulatedMinute: 3, oxygen: 94, respiratoryRate: 13, heartRate: 62, rmssd: 33, watchHeartRate: 63, risk: 38, tier: .watch),
        Frame(simulatedMinute: 4, oxygen: 91, respiratoryRate: 11, heartRate: 58, rmssd: 27, watchHeartRate: 59, risk: 61, tier: .watch),
        Frame(simulatedMinute: 5, oxygen: 87, respiratoryRate: 9, heartRate: 53, rmssd: 21, watchHeartRate: 54, risk: 78, tier: .confirm),
        Frame(simulatedMinute: 6, oxygen: 82, respiratoryRate: 7, heartRate: 48, rmssd: 16, watchHeartRate: 49, risk: 94, tier: .confirm),
        Frame(simulatedMinute: 7, oxygen: 78, respiratoryRate: 5, heartRate: 43, rmssd: 12, watchHeartRate: 44, risk: 98, tier: .klaxon)
    ]

    @State private var monitoring = false
    @State private var isStarting = false
    @State private var frameIndex = 0
    @State private var autoStarted = false
    @State private var pulseAlarm = false

    private var frame: Frame { frames[frameIndex] }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    if monitoring {
                        sensorStrip
                        riskCard
                        signalGrid
                        timeline
                        if frame.tier == .klaxon { emergencyCard }
                    } else {
                        setupCard
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }

            if frame.tier == .klaxon {
                klaxonBanner
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .navigationTitle("CNS Monitoring")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: frameIndex)
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("-demoCNSSequence") || args.contains("-demoCNSVideo"), !autoStarted else { return }
            autoStarted = true
            try? await Task.sleep(for: .seconds(2.2))
            beginMonitoring()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(monitoring ? "MONITORING ACTIVE" : "READY TO MONITOR")
                    .font(.caption.bold())
                    .foregroundStyle(monitoring ? .green : .secondary)
                Text(monitoring ? "Three-device physiological safety watch" : "CNS-depression early warning")
                    .font(.headline)
            }
            Spacer()
            Image(systemName: monitoring ? "waveform.path.ecg" : "shield")
                .font(.title2)
                .foregroundStyle(monitoring ? .green : .secondary)
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connected monitoring sources", systemImage: "sensor.tag.radiowaves.forward.fill")
                .font(.headline)
            sourceRow("EMAY SleepO₂", detail: "Continuous SpO₂ + respiratory rate", icon: "lungs.fill", color: .blue)
            sourceRow("Polar H10", detail: "ECG heart rate + HRV", icon: "heart.fill", color: .red)
            sourceRow("Apple Watch", detail: "Corroborating heart rate", icon: "applewatch", color: .green)
            Button {
                beginMonitoring()
            } label: {
                Label(isStarting ? "Starting monitoring…" : "Monitor me now", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStarting)
            Text("SIMULATION • No alarm or health record will be created")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private var sensorStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("REPORTING LIVE").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("7 min simulated").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                sensorPill("EMAY", icon: "lungs.fill", color: .blue)
                sensorPill("Polar H10", icon: "heart.fill", color: .red)
                sensorPill("Apple Watch", icon: "applewatch", color: .green)
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private var riskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(frame.tier.title.uppercased(), systemImage: frame.tier.icon)
                    .font(.headline.bold())
                    .foregroundStyle(frame.tier.color)
                Spacer()
                Text("\(frame.risk)% RISK")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(frame.tier.color)
            }
            ProgressView(value: Double(frame.risk), total: 100)
                .tint(frame.tier.color)
                .scaleEffect(y: 1.8)
            Text(tierMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(frame.tier.color.opacity(0.1), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).stroke(frame.tier.color.opacity(0.35), lineWidth: 1)
        }
    }

    private var signalGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
            metricCard("Blood oxygen", value: "\(frame.oxygen)%", source: "EMAY", icon: "lungs.fill", color: oxygenColor)
            metricCard("Respiratory rate", value: "\(frame.respiratoryRate)/min", source: "EMAY", icon: "wind", color: oxygenColor)
            metricCard("ECG heart rate", value: "\(frame.heartRate) bpm", source: "Polar H10", icon: "heart.fill", color: heartColor)
            metricCard("HRV (RMSSD)", value: "\(frame.rmssd) ms", source: "Polar H10", icon: "waveform.path.ecg", color: heartColor)
            metricCard(
                "Watch heart rate",
                value: "\(frame.watchHeartRate) bpm",
                source: "Apple Watch",
                icon: "applewatch",
                color: heartColor
            )
            metricCard(
                "Signal confidence",
                value: isHighRisk ? "High" : "Good",
                source: "3 sources",
                icon: "checkmark.seal.fill",
                color: .green
            )
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ACCELERATED TIMELINE").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("Minute \(frame.simulatedMinute)").font(.caption.monospacedDigit())
            }
            HStack(spacing: 4) {
                ForEach(frames.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= frameIndex ? frames[index].tier.color : Color.secondary.opacity(0.2))
                        .frame(height: 7)
                }
            }
            Text("Clear → Watch → Confirm → Klaxon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 18))
    }

    private var emergencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OVERDOSE KLAXON CONDITION", systemImage: "speaker.wave.3.fill")
                .font(.headline.bold())
                .foregroundStyle(.red)
            Text("Critical sustained oxygen and breathing decline detected across continuous primary and corroborating signals.")
                .font(.subheadline)
            Text("Wake the person and check breathing. Call emergency services if they are difficult to wake or breathing is slow or stopped.")
                .font(.subheadline.bold())
            SlideToAcknowledgeView(title: "Slide to acknowledge alarm") {}
        }
        .padding(16)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.red, lineWidth: 2) }
    }

    private var klaxonBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.title2)
                .symbolEffect(.bounce, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("CRITICAL CNS ALERT").font(.headline.bold())
                Text("Klaxon condition • Check breathing now").font(.caption)
            }
            Spacer()
            Text("NOW").font(.caption.bold())
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.red.gradient, in: .rect(cornerRadius: 16))
        .scaleEffect(pulseAlarm ? 1.015 : 1)
        .shadow(color: .red.opacity(0.45), radius: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulseAlarm = true
            }
        }
    }

    private var tierMessage: String {
        switch frame.tier {
        case .clear: "Signals are stable near the starting range."
        case .watch: "Oxygen and breathing are declining; monitoring more closely."
        case .confirm: "Multiple sources confirm a dangerous physiological decline."
        case .klaxon: "Critical primary evidence sustained: urgent response indicated."
        }
    }

    private var isHighRisk: Bool { frame.tier.rawValue >= Tier.confirm.rawValue }
    private var oxygenColor: Color { isHighRisk ? .red : frame.tier == .watch ? .orange : .blue }
    private var heartColor: Color { isHighRisk ? .orange : .red }

    private func sourceRow(_ title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func sensorPill(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(color.opacity(0.11), in: .capsule)
    }

    private func metricCard(_ title: String, value: String, source: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(source).font(.caption2.bold()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.background, in: .rect(cornerRadius: 15))
    }

    private func beginMonitoring() {
        guard !monitoring, !isStarting else { return }
        isStarting = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            monitoring = true
            isStarting = false
            for index in frames.indices.dropFirst() {
                try? await Task.sleep(for: .seconds(2.35))
                frameIndex = index
            }
        }
    }
}
#endif
