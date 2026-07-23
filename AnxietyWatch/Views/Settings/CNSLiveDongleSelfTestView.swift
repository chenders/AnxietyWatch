#if DEBUG
import SwiftUI
import SwiftData
import OSLog

/// DEBUG-only LIVE self-test: connects to the EMAY dongle over real Bluetooth
/// and runs the REAL `CNSMonitoringCoordinator` against its stream — doing every
/// real step (quality gate → severity → fusion → escalation, device-state,
/// dead-man's-switch) — but wired to an IN-MEMORY store, so **nothing is ever
/// written to your real records**. Point the dongle at a slow desaturation and
/// watch the genuine pipeline escalate clear → watch → confirm → klaxon on real
/// radio data.
///
/// Record-safety: both the dedicated `EMAYRealtimeService` and the
/// `CNSMonitoringCoordinator` are constructed with `ModelContext`s over an
/// in-memory `ModelContainer` (same schema as the app, `isStoredInMemoryOnly`),
/// which is discarded when the view goes away. The app's container is read only
/// for its `schema` (to build the matching in-memory store — see the
/// `appContext.container.schema` copy below); nothing is ever written to the
/// real `sharedModelContainer`.
struct CNSLiveDongleSelfTestView: View {
    private let log = Logger(subsystem: "com.anxietywatch.app", category: "CNSLiveSelfTest")

    @Environment(\.modelContext) private var appContext

    @State private var emay: EMAYRealtimeService?
    @State private var coordinator: CNSMonitoringCoordinator?
    @State private var running = false
    @State private var setupError: String?
    @State private var maxTier: CNSAlertTier = .clear
    @State private var alertEngine = CNSAlertEngine()

    var body: some View {
        List {
            controlSection
            if let setupError { errorSection(setupError) }
            if running {
                connectionSection
                readingSection
                engineSection
                resultSection
            }
        }
        .navigationTitle("Live Dongle Self-Test")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: coordinator?.currentTier) { _, tier in
            guard let tier else { return }
            if tier.rawValue > maxTier.rawValue { maxTier = tier }
            alertEngine.update(for: tier)   // escalate sound + haptics with the tier
        }
        .onDisappear { stop() }
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section {
            if running {
                Button(role: .destructive) { stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { start() } label: {
                    Label("Run with live dongle", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        } footer: {
            Text("Connects to the EMAY dongle over real Bluetooth and runs the real detection engine on its "
                + "live stream. Everything runs against an in-memory store — no health records, monitoring "
                + "sessions, or samples are written. As the tier rises you'll hear an escalating alert "
                + "(heads-up chime → warning beep → loud klaxon) with haptics; Stop silences it. Disarm CNS "
                + "Monitoring and leave the EMAY Live screen first, or the app's own EMAY connection competes "
                + "for the dongle.")
        }
    }

    private func errorSection(_ error: String) -> some View {
        Section("Setup error") {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private var connectionSection: some View {
        Section("Dongle connection") {
            LabeledContent("Bluetooth", value: connectionText)
        }
    }

    private var readingSection: some View {
        Section("Live from dongle") {
            if let reading = emay?.latestReading {
                LabeledContent("SpO₂", value: reading.spo2.map { "\($0)%" } ?? "—")
                LabeledContent("Pulse", value: reading.pulseRate.map { "\($0) bpm" } ?? "—")
            } else {
                Text("Waiting for the first frame…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var engineSection: some View {
        Section("Detection engine (real pipeline)") {
            if let coordinator {
                tierRow(coordinator.currentTier)
                LabeledContent("Status", value: coordinator.statusLine)
                LabeledContent("Can assess", value: coordinator.canAssess ? "Yes" : "Not yet")
                LabeledContent("Reporting sources", value: reportingText(coordinator))
            }
        }
    }

    private var resultSection: some View {
        Section("Result") {
            LabeledContent("Highest tier reached") {
                Label(tierTitle(maxTier), systemImage: tierIcon(maxTier))
                    .foregroundStyle(tierColor(maxTier)).fontWeight(.semibold)
            }
            if maxTier == .klaxon {
                Label("KLAXON — the real engine escalated on live dongle data.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func tierRow(_ tier: CNSAlertTier) -> some View {
        HStack(spacing: 12) {
            Image(systemName: tierIcon(tier)).font(.title2).foregroundStyle(tierColor(tier))
            VStack(alignment: .leading, spacing: 2) {
                Text(tierTitle(tier)).font(.headline)
                Text("real coordinator, in-memory store").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lifecycle

    private func start() {
        setupError = nil
        maxTier = .clear
        do {
            // In-memory twin of the app schema — every write is discarded.
            let schema = appContext.container.schema
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [config])

            // restoreIdentifier: nil — a second CBCentralManager sharing the
            // app service's restore identifier would come up `.unsupported`.
            // targetName — connect ONLY to the emulator dongle, never the real
            // EMAY oximeter (both advertise the FF12 service).
            let emayService = EMAYRealtimeService(
                modelContext: ModelContext(container),
                restoreIdentifier: nil,
                targetName: "SleepO2-SIM"
            )
            let coord = CNSMonitoringCoordinator(
                modelContext: ModelContext(container),
                latestEMAYReading: { [weak emayService] in emayService?.latestReading },
                latestPolarHR: { nil },
                latestPolarRMSSD: { nil },
                notificationPoster: UNUserNotificationCenterPoster(),
                emayStartHook: { [weak emayService] in emayService?.start() },
                emayStopHook: { [weak emayService] in emayService?.stop() }
            )
            emay = emayService
            coordinator = coord
            running = true
            coord.armAdHoc()   // arms → emayStartHook → scan FF12 → connect → 1 Hz tick loop
            log.debug("Live dongle self-test armed (in-memory store, real coordinator)")
        } catch {
            setupError = "Couldn't create in-memory store: \(error.localizedDescription)"
            log.error("Live self-test setup failed: \(error.localizedDescription)")
        }
    }

    private func stop() {
        alertEngine.silence()
        coordinator?.disarm()
        coordinator = nil
        emay?.stop()
        emay = nil
        running = false
    }

    // MARK: - Labels

    private var connectionText: String {
        switch emay?.status {
        case .idle: "Idle"
        case .scanning: "Scanning for FF12…"
        case .waitingForDevice: "Waiting for device…"
        case .connecting: "Connecting…"
        case .streaming: "Connected — streaming"
        case .failed(let message): "Failed: \(message)"
        case .bluetoothOff: "Bluetooth is OFF"
        case .bluetoothUnauthorized: "Bluetooth permission denied (Settings → AnxietyWatch)"
        case .bluetoothUnsupported: "Bluetooth unsupported on this device"
        case nil: "—"
        }
    }

    private func reportingText(_ coordinator: CNSMonitoringCoordinator) -> String {
        guard !coordinator.reportingSources.isEmpty else { return "None" }
        return coordinator.reportingSources
            .map {
                switch $0 {
                case .emayOximeter: "EMAY"
                case .polarH10: "Polar H10"
                case .appleWatch: "Apple Watch"
                case .as11Bridge: "AS11"
                }
            }
            .sorted()
            .joined(separator: ", ")
    }

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
}
#endif
