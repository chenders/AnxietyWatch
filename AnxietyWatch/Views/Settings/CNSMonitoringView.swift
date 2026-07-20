import SwiftData
import SwiftUI

/// Minimal, functional CNS-depression monitoring surface (klaxon Phase 2,
/// plan decision 10). Plain SwiftUI `List` — no styling ambitions; Phase 3
/// redesigns this screen entirely once the alerting engine (klaxon/haptics,
/// the ~1-hour history view) lands. Every control here writes straight
/// through to `CNSMonitoringCoordinator`/`CNSDeviceFallbackConfig`; there is
/// no local view-model, matching the rest of the Settings surface
/// (`PolarSettingsView`/`EMAYLiveView`).
struct CNSMonitoringView: View {
    @Environment(CNSMonitoringCoordinator.self) private var coordinator
    @State private var fallbackConfig = CNSDeviceFallbackConfig.load(from: .standard)
    @State private var permission: CNSNotifyPermission?

    var body: some View {
        List {
            armingSection
            if coordinator.currentTier >= .confirm && coordinator.isMonitoring {
                alarmActionSection
            }
            statusSection
            permissionSection
            fallbackSection
        }
        .navigationTitle("CNS Monitoring")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            permission = await CNSCriticalAlertPermission().currentStatus()
        }
    }

    // MARK: - Arm / disarm / companion

    private var armingSection: some View {
        Section {
            Toggle("Monitor tonight", isOn: manualArmBinding)
            Button("Monitor me now") {
                coordinator.armAdHoc()
            }
            Toggle(
                "Companion present",
                isOn: Binding(
                    get: { coordinator.companionPresent },
                    set: { coordinator.setCompanionPresent($0) }
                )
            )
        } footer: {
            Text(
                "If they leave, re-mark alone — thresholds re-tighten. Arming (any option) "
                    + "starts the EMAY oximeter session automatically; it never overrides your "
                    + "EMAY continuous-streaming setting. Turning off \"Monitor tonight\" stops ALL "
                    + "monitoring, including ad-hoc and dose-window triggers — this is intentional, "
                    + "not a bug."
            )
        }
    }

    /// "Monitor tonight" maps onto the `.manual` trigger. Turning it OFF
    /// calls `disarm()` rather than trying to remove just the `.manual`
    /// trigger — the coordinator's public surface has no partial-trigger
    /// removal, and `disarm()`'s documented contract ("manual disarm always
    /// wins") is exactly the right behavior for this screen's single
    /// explicit "stop" control. Turning it ON while already monitoring for
    /// another reason (ad-hoc/dose-window) just adds `.manual` to the active
    /// set without resetting the session (see `armManually`'s own
    /// early-return-into-`insert` branch) — thresholds/escalation state
    /// survive.
    private var manualArmBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isMonitoring && coordinator.activeTriggers.contains(.manual) },
            set: { isOn in
                if isOn {
                    coordinator.armManually(companionPresent: coordinator.companionPresent)
                } else {
                    coordinator.disarm()
                }
            }
        )
    }

    // MARK: - Status

    private var alarmActionSection: some View {
        Section {
            SlideToAcknowledgeView(title: "Slide to acknowledge alarm") {
                // To acknowledge, we stop monitoring (the user's deliberate intervention)
                coordinator.disarm()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 8)
        }
    }

    private var statusSection: some View {
        Section {
            Text(coordinator.statusLine)
            Text(CNSMonitoringViewHelpers.alarmStateSubtitle(isMonitoring: coordinator.isMonitoring, tier: coordinator.currentTier))
                .font(.caption)
                .foregroundColor(coordinator.currentTier >= .confirm ? .red : .secondary)
            LabeledContent("Tier", value: CNSMonitoringViewHelpers.tierText(coordinator.currentTier))
            LabeledContent("Reporting", value: reportingSourcesText)
            LabeledContent("Active triggers", value: activeTriggersText)
            if coordinator.activeTriggers.contains(.doseWindow), let expiry = coordinator.doseWindowExpiry {
                LabeledContent("Dose window expires") {
                    Text(expiry, style: .relative)
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text("If you force-quit the app or reboot your phone, monitoring will stop until you reopen the app.")
        }
    }

    private var permissionSection: some View {
        Section {
            LabeledContent("Status", value: CNSMonitoringViewHelpers.permissionStatusLabel(permission))
            if let status = permission, status != .criticalGranted && status != .denied {
                Button("Request Critical Alerts") {
                    Task {
                        permission = await CNSCriticalAlertPermission().requestIfNeeded()
                    }
                }
            }
        } header: {
            Text("Alarm Permissions")
        }
    }

    private var reportingSourcesText: String {
        guard !coordinator.reportingSources.isEmpty else { return "None" }
        return coordinator.reportingSources
            .map(sourceLabel)
            .sorted()
            .joined(separator: ", ")
    }

    private var activeTriggersText: String {
        guard !coordinator.activeTriggers.isEmpty else { return "None" }
        return coordinator.activeTriggers
            .map(triggerLabel)
            .sorted()
            .joined(separator: ", ")
    }

    private func sourceLabel(_ source: CNSSignalSource) -> String {
        switch source {
        case .emayOximeter: "EMAY Oximeter"
        case .polarH10: "Polar H10"
        case .appleWatch: "Apple Watch"
        case .as11Bridge: "AS11 Bridge"
        }
    }

    private func triggerLabel(_ trigger: CNSMonitoringCoordinator.ActivationTrigger) -> String {
        switch trigger {
        case .manual: "Manual"
        case .doseWindow: "Dose window"
        case .adHoc: "Ad hoc"
        }
    }

    // MARK: - Per-device fallback

    private var fallbackSection: some View {
        Section {
            Picker("EMAY oximeter", selection: $fallbackConfig.emay) {
                fallbackActionOptions
            }
            Picker("Polar H10", selection: $fallbackConfig.polar) {
                fallbackActionOptions
            }
            Picker("Apple Watch", selection: $fallbackConfig.appleWatch) {
                fallbackActionOptions
            }
        } header: {
            Text("If a device stops reporting")
        } footer: {
            Text(
                "While the app is running, a notification is sent immediately for device loss "
                    + "or degradation, regardless of this choice — never silent. If monitoring is "
                    + "interrupted in the background (the app is suspended or closed), a watchdog "
                    + "notification fires within about 90 seconds so you know to reopen the app. "
                    + "Phase 3's alerting engine is what actually sounds the klaxon or gentle alarm."
            )
        }
        .onChange(of: fallbackConfig) { _, newValue in
            newValue.save(to: .standard)
        }
    }

    @ViewBuilder
    private var fallbackActionOptions: some View {
        ForEach(CNSDeviceFallbackConfig.Action.allCases, id: \.self) { action in
            Text(fallbackActionLabel(action)).tag(action)
        }
    }

    private func fallbackActionLabel(_ action: CNSDeviceFallbackConfig.Action) -> String {
        switch action {
        case .klaxon: "Klaxon"
        case .gentleAlarm: "Gentle alarm"
        case .notifyOnly: "Notify only"
        }
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        CNSMonitoringView()
            .modelContainer(container)
            .environment(CNSMonitoringCoordinator(
                modelContext: ModelContext(container),
                latestEMAYReading: { nil },
                latestPolarHR: { nil },
                latestPolarRMSSD: { nil },
                notificationPoster: UNUserNotificationCenterPoster(),
                enableTickLoop: false
            ))
    }
}
#endif
