import SwiftUI
import AuthenticationServices
import AnxietyWatchKit

struct OuraSettingsView: View {
    private enum ConnectionStatus {
        case connected
        case disconnected
        case notConfigured

        var title: String {
            switch self {
            case .connected: "Connected"
            case .disconnected: "Disconnected"
            case .notConfigured: "Not Configured"
            }
        }

        var systemImage: String {
            switch self {
            case .connected: "checkmark.circle.fill"
            case .disconnected: "exclamationmark.circle.fill"
            case .notConfigured: "minus.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .connected: .green
            case .disconnected: .orange
            case .notConfigured: .secondary
            }
        }
    }

    private let tokenStore: OuraTokenStore
    private let service: OuraService
    private let healthKitAdapter: OuraHealthKitAdapter

    @State private var connectionStatus: ConnectionStatus = .notConfigured
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Non-fatal warning shown when the token is stored locally but couldn't be
    /// pushed to the sync server — the server-side background pull won't run
    /// until reconnected. Distinct from a full connection failure.
    @State private var serverSyncWarning: String?
    @State private var oauthManager = OuraOAuthManager()
#if DEBUG
    @State private var demoDataPresented = false
#endif

    @AppStorage("oura.healthKitBridgingEnabled")
    private var healthKitBridgingEnabled = false

    @AppStorage("oura.lastSyncTimeInterval")
    private var lastSyncTimeInterval: Double = 0

    init(
        tokenStore: OuraTokenStore = OuraTokenStore(),
        service: OuraService = OuraService(),
        healthKitAdapter: OuraHealthKitAdapter = OuraHealthKitAdapter()
    ) {
        self.tokenStore = tokenStore
        self.service = service
        self.healthKitAdapter = healthKitAdapter
    }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    Label(connectionStatus.title, systemImage: connectionStatus.systemImage)
                        .foregroundStyle(connectionStatus.color)
                }

                LabeledContent("Last Sync") {
                    if let lastSyncDate {
                        Text(lastSyncDate, format: .dateTime.month().day().year().hour().minute())
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                if let serverSyncWarning {
                    Label(serverSyncWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { await connectOAuth() }
                } label: {
                    if isSaving {
                        HStack {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Text(connectionStatus == .notConfigured ? "Connect with Oura" : "Reconnect with Oura")
                    }
                }
                .disabled(isSaving)

                if connectionStatus != .notConfigured {
                    Button("Disconnect", role: .destructive) {
                        Task { await disconnect() }
                    }
                    .disabled(isSaving)
                }
            } header: {
                Text("Oura Account")
            } footer: {
                Text("Anxiety Watch will open a browser to securely authenticate with your Oura account. "
                    + "Disconnecting removes the token from this device only; your sync server keeps its "
                    + "copy until it is removed there.")
            }

            Section("Data") {
                NavigationLink {
                    OuraDataDashboardView(service: service)
                } label: {
                    Label("View All Oura Data", systemImage: "chart.xyaxis.line")
                }
            }

            Section {
                Toggle("Bridge Oura Data to HealthKit", isOn: $healthKitBridgingEnabled)
                    .onChange(of: healthKitBridgingEnabled) { _, enabled in
                        guard enabled else { return }
                        Task { await enableHealthKitBridging() }
                    }
            } footer: {
                Text("When enabled, Anxiety Watch requests access to Oura-related sleep and blood oxygen data in Apple Health.")
            }
        }
        .navigationTitle("Oura Ring")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isLoading)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task {
            await loadConnectionStatus()
        }
#if DEBUG
        .navigationDestination(isPresented: $demoDataPresented) {
            OuraDataDashboardView(service: service)
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-demoOuraSequence") else { return }
            // Show connection, provenance, and HealthKit bridge state before
            // opening the same complete-data destination as the visible row.
            try? await Task.sleep(for: .seconds(4))
            demoDataPresented = true
        }
#endif
        .alert("Oura Connection", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var lastSyncDate: Date? {
#if targetEnvironment(simulator)
        return Date().addingTimeInterval(-180)
#else
        guard lastSyncTimeInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: lastSyncTimeInterval)
#endif
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func loadConnectionStatus() async {
        defer { isLoading = false }

#if targetEnvironment(simulator)
        connectionStatus = .connected
        healthKitBridgingEnabled = true
        return
#else
        do {
            guard let storedToken = try tokenStore.read() else {
                connectionStatus = .notConfigured
                return
            }
            connectionStatus = storedToken.isExpired ? .disconnected : .connected
        } catch {
            connectionStatus = .disconnected
            errorMessage = "The saved Oura token could not be read."
        }
#endif
    }

    @MainActor
    private func connectOAuth() async {
        isSaving = true
        let previousStatus = connectionStatus
        serverSyncWarning = nil
        defer { isSaving = false }

        do {
            let credential = try await oauthManager.authenticate()
            await service.configure(token: credential)

            guard await service.isAuthenticated else {
                connectionStatus = .disconnected
                errorMessage = "Oura could not be connected."
                return
            }
            connectionStatus = .connected
            await postTokenToServerIfConfigured(credential)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user dismissed the auth sheet — a normal action, not a
            // failure. Restore the prior state without an alert.
            connectionStatus = previousStatus
        } catch {
            connectionStatus = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    /// Push the freshly-obtained token to the sync server so the server-side
    /// webhook worker can pull Oura data. The local connection is already
    /// established at this point; a server-post failure is surfaced as a
    /// non-fatal warning (own-failure-visible) rather than silently swallowed —
    /// otherwise the user sees a clean "Connected" while background pull never
    /// runs. When sync isn't configured at all, there's nothing to post to and
    /// local-only is a valid state.
    @MainActor
    private func postTokenToServerIfConfigured(_ credential: OuraTokenStore.Token) async {
        let serverURL = (UserDefaults.standard.string(forKey: SyncService.serverURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (UserDefaults.standard.string(forKey: SyncService.apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !apiKey.isEmpty else { return }

        do {
            try await service.postTokenToServer(baseURL: serverURL, apiKey: apiKey, token: credential)
            serverSyncWarning = nil
        } catch {
            serverSyncWarning = "Connected on this device, but couldn't reach your sync server — "
                + "background data pull won't run until you reconnect."
        }
    }

    @MainActor
    private func disconnect() async {
        isSaving = true
        defer { isSaving = false }

        await service.stopPolling()
        do {
            try tokenStore.delete()
            connectionStatus = .notConfigured
            serverSyncWarning = nil
            lastSyncTimeInterval = 0
        } catch {
            errorMessage = "The saved Oura token could not be removed."
        }
    }

    @MainActor
    private func enableHealthKitBridging() async {
        do {
            try await healthKitAdapter.requestPermissions()
        } catch {
            healthKitBridgingEnabled = false
            errorMessage = "HealthKit access could not be enabled. You can review access in the Health app."
        }
    }
}
