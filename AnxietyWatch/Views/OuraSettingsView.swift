import SwiftUI
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

    @State private var token = ""
    @State private var connectionStatus: ConnectionStatus = .notConfigured
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

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
            }

            Section {
                SecureField("Personal access token", text: $token)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()

                Button {
                    Task { await saveToken() }
                } label: {
                    if isSaving {
                        HStack {
                            ProgressView()
                            Text("Saving…")
                        }
                    } else {
                        Text(connectionStatus == .notConfigured ? "Connect" : "Update Token")
                    }
                }
                .disabled(trimmedToken.isEmpty || isSaving)

                if connectionStatus != .notConfigured {
                    Button("Disconnect", role: .destructive) {
                        Task { await disconnect() }
                    }
                    .disabled(isSaving)
                }
            } header: {
                Text("Personal Access Token")
            } footer: {
                Text("Your token is stored securely in the system Keychain. Leave this field blank unless you want to replace it.")
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
        .alert("Oura Connection", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private func saveToken() async {
        let accessToken = trimmedToken
        guard !accessToken.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let credential = OuraTokenStore.Token(
            accessToken: accessToken,
            refreshToken: "",
            expiresAt: .distantFuture
        )
        await service.configure(token: credential)

        if await service.isAuthenticated {
            token = ""
            connectionStatus = .connected
        } else {
            connectionStatus = .disconnected
            errorMessage = "Oura could not be connected with that token."
        }
    }

    @MainActor
    private func disconnect() async {
        isSaving = true
        defer { isSaving = false }

        await service.stopPolling()
        do {
            try tokenStore.delete()
            token = ""
            connectionStatus = .notConfigured
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
