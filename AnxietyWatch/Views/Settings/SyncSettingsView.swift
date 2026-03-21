import SwiftData
import SwiftUI

struct SyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    private let sync = SyncService.shared

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var autoSync: Bool = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL, prompt: Text("https://your-server.com"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: serverURL) { _, val in sync.serverURL = val }

                SecureField("API Key", text: $apiKey, prompt: Text("Bearer token"))
                    .textContentType(.password)
                    .onChange(of: apiKey) { _, val in sync.apiKey = val }
            }

            Section("Sync") {
                Toggle("Auto-sync on launch", isOn: $autoSync)
                    .onChange(of: autoSync) { _, val in sync.autoSyncEnabled = val }

                Button {
                    Task { await sync.sync(modelContext: modelContext) }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        if sync.isSyncing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!sync.isConfigured || sync.isSyncing)

                Button {
                    Task { await sync.fullSync(modelContext: modelContext) }
                } label: {
                    Label("Full Re-sync", systemImage: "arrow.clockwise.circle")
                }
                .disabled(!sync.isConfigured || sync.isSyncing)
            }

            Section("Status") {
                if let date = sync.lastSyncDate {
                    LabeledContent("Last sync", value: date.formatted(.dateTime))
                } else {
                    LabeledContent("Last sync", value: "Never")
                }

                if let result = sync.lastSyncResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("failed") || result.contains("error")
                            ? .red : .secondary)
                }
            }

            Section("API Contract") {
                Text("""
                    The app POSTs JSON to {url}/api/sync with header \
                    "Authorization: Bearer {key}". Payload matches the \
                    JSON export format with added sync metadata. \
                    Server should return 2xx on success.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Server Sync")
        .onAppear {
            serverURL = sync.serverURL
            apiKey = sync.apiKey
            autoSync = sync.autoSyncEnabled
        }
    }
}
