import SwiftData
import SwiftUI

struct SyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    private let sync = SyncService.shared

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var autoSync: Bool = false
    @State private var restoreResult: String?
    @State private var isRestoring: Bool = false
    @State private var showRestoreConfirmation: Bool = false
    @State private var reconcileResult: String?
    @State private var isReconciling: Bool = false
    @State private var showReconcileConfirmation: Bool = false

    /// True while ANY sync-family operation is in flight.
    ///
    /// Before reconcile existed, overlap didn't matter: `restoreFromServer` could
    /// only run against an empty store, so a concurrent `sync()` had nothing to
    /// collide with. Reconcile is specifically designed to run against a populated,
    /// actively-syncing store — so a background auto-sync firing while the user taps
    /// "Repair" is now a realistic interleaving, and both mutate the same
    /// `modelContext` across `await` suspension points (network round trips) where
    /// the other can run. Gate all four buttons on one flag rather than each on its
    /// own (the state-machine-completeness pitfall in CLAUDE.md).
    private var syncFamilyBusy: Bool {
        sync.isSyncing || isRestoring || isReconciling
    }

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
                .disabled(!sync.isConfigured || syncFamilyBusy)

                Button {
                    Task { await sync.fullSync(modelContext: modelContext) }
                } label: {
                    Label("Full Re-sync", systemImage: "arrow.clockwise.circle")
                }
                .disabled(!sync.isConfigured || syncFamilyBusy)
            }

            Section("Restore from Server") {
                Text("Downloads your complete history from the sync server "
                    + "into this device. For rebuilding after a fresh install — "
                    + "only runs while the local store is empty. Does not "
                    + "affect server data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showRestoreConfirmation = true
                } label: {
                    HStack {
                        Label("Restore from Server", systemImage: "arrow.down.circle")
                        if isRestoring {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!sync.isConfigured || syncFamilyBusy)
                .confirmationDialog(
                    "Restore all data from the server?",
                    isPresented: $showRestoreConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Restore") { runRestore() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Downloads your complete history into this device's "
                        + "empty local store. Server data is not modified.")
                }

                if let result = restoreResult {
                    Text(result)
                        .font(.caption.monospaced())
                        .foregroundStyle(result.hasPrefix("Failed") ? .red : .secondary)
                }
            }

            Section("Repair from Server") {
                Text("Downloads anything the server has that this device is "
                    + "missing. Rows you already have are skipped, never "
                    + "overwritten — if a row differs, your device's copy wins. "
                    + "Unlike Restore, this works on a device that already has "
                    + "data. Nothing is deleted, on the device or the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showReconcileConfirmation = true
                } label: {
                    HStack {
                        Label("Repair Missing Data", systemImage: "arrow.triangle.merge")
                        if isReconciling {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!sync.isConfigured || syncFamilyBusy)
                .confirmationDialog(
                    "Download missing data from the server?",
                    isPresented: $showReconcileConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Repair") { runReconcile() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Adds only the rows this device is missing. Existing rows "
                        + "are skipped, not overwritten, and nothing is deleted. "
                        + "This may take a few minutes on a large history.")
                }

                if let result = reconcileResult {
                    Text(result)
                        .font(.caption.monospaced())
                        .foregroundStyle(result.hasPrefix("Failed") ? .red : .secondary)
                }
            }

            Section("Status") {
                lastSuccessRow

                if let line = SyncStatusPresentation.statusLine(
                    lastResult: sync.lastSyncResult,
                    outcome: sync.lastRunOutcome
                ) {
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(foregroundStyle(for: line.style))
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

    /// "Last successful sync" row — sourced from `lastKnownSuccessDate`
    /// (the success timestamp, falling back to the incremental cursor for
    /// installs that synced before the timestamp existed), NOT the raw
    /// cursor: `fullSync()` nils the cursor mid-run and bulk-only drain
    /// iterations never advance it, so the cursor alone can't honestly
    /// answer "when did data last reach the server". Warns (orange +
    /// triangle) when auto-sync is on, the sync is configured (no orange
    /// "Never" while the user is still typing a server URL), and the
    /// server hasn't received data in over 7 days — the silent-outage
    /// signal this screen existed without for a month.
    private var lastSuccessRow: some View {
        let staleness = SyncStatusPresentation.stalenessLine(
            lastSuccess: sync.lastKnownSuccessDate,
            autoSyncEnabled: sync.autoSyncEnabled,
            isConfigured: sync.isConfigured,
            now: .now
        )
        return LabeledContent("Last successful sync") {
            if staleness.isWarning {
                Label(staleness.text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(staleness.text)
            }
        }
    }

    private func foregroundStyle(for style: SyncStatusPresentation.StatusLine.Style) -> AnyShapeStyle {
        switch style {
        case .info: AnyShapeStyle(.secondary)
        case .success: AnyShapeStyle(.green)
        case .warning: AnyShapeStyle(.orange)
        case .error: AnyShapeStyle(.red)
        }
    }

    /// Production restore: truthful timestamps (no demo date shift). The
    /// empty-store guard inside `restoreFromServer` surfaces as a "Failed:"
    /// message when the store already has data.
    private func runRestore() {
        Task {
            isRestoring = true
            restoreResult = nil
            do {
                let report = try await sync.restoreFromServer(modelContext: modelContext)
                restoreResult = report
            } catch {
                restoreResult = "Failed: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    /// Heal a populated store: pull down only what's missing. Unlike `runRestore`
    /// there is no empty-store precondition, and the sync cursor is deliberately
    /// left alone — see `RestoreMode.reconcile`.
    private func runReconcile() {
        Task {
            isReconciling = true
            reconcileResult = nil
            do {
                let report = try await sync.reconcileFromServer(modelContext: modelContext)
                // The report counts rows ADDED, not rows seen — every importer
                // skips what's already present. An all-zero report is the good
                // outcome: nothing was missing.
                reconcileResult = report
            } catch {
                reconcileResult = "Failed: \(error.localizedDescription)"
            }
            isReconciling = false
        }
    }
}
