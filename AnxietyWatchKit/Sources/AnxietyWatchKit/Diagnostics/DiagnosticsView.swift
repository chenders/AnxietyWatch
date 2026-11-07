import Foundation
import SwiftUI

// MARK: - DiagnosticsSnapshot

/// Immutable, Sendable, Codable snapshot of the full framework state
/// at a point in time. The app layer periodically calls actor-isolated
/// getters, assembles this struct on whichever actor it runs on, and
/// hands it to DiagnosticsView. The view never touches any actor directly.
public struct DiagnosticsSnapshot: Sendable, Equatable, Codable {

    // MARK: Pipeline

    public struct Pipeline: Sendable, Equatable, Codable {
        public var vitalsStatus: VitalsStatus
        public var isRunning: Bool

        public init(vitalsStatus: VitalsStatus = .idle, isRunning: Bool = false) {
            self.vitalsStatus = vitalsStatus
            self.isRunning = isRunning
        }
    }

    // MARK: Sync cursors

    public struct CursorNode: Sendable, Equatable, Codable {
        public var nodeID: Data
        public var nodeIDSuffix: String   // last 4 hex chars for display
        public var pullSamplesHLC: Int64
        public var pushSamplesHLC: Int64
        public var pullTombstonesHLC: Int64
        public var pushTombstonesHLC: Int64

        public init(nodeID: Data, pullSamplesHLC: Int64 = 0, pushSamplesHLC: Int64 = 0,
                    pullTombstonesHLC: Int64 = 0, pushTombstonesHLC: Int64 = 0) {
            self.nodeID = nodeID
            self.nodeIDSuffix = nodeID.count >= 2
                ? nodeID.suffix(2).map { String(format: "%02X", $0) }.joined()
                : "??"
            self.pullSamplesHLC = pullSamplesHLC
            self.pushSamplesHLC = pushSamplesHLC
            self.pullTombstonesHLC = pullTombstonesHLC
            self.pushTombstonesHLC = pushTombstonesHLC
        }
    }

    public struct SyncCursors: Sendable, Equatable, Codable {
        public var perNode: [CursorNode]

        public init(perNode: [CursorNode] = []) {
            self.perNode = perNode
        }
    }

    // MARK: Source idle states

    public struct SourceState: Sendable, Equatable, Codable {
        public var name: String
        public var lastFrameAt: Double?       // seconds since reference date, nil = never
        public var secondsSinceLastFrame: Double?
        public var isIdle: Bool

        public init(name: String, lastFrameAt: Double? = nil,
                    secondsSinceLastFrame: Double? = nil, isIdle: Bool = false) {
            self.name = name
            self.lastFrameAt = lastFrameAt
            self.secondsSinceLastFrame = secondsSinceLastFrame
            self.isIdle = isIdle
        }
    }

    // MARK: System

    public struct System: Sendable, Equatable, Codable {
        public var clockSuspect: Bool
        public var lastPanicResult: String
        public var dbSizeBytes: Int64
        public var nodeIDSuffix: String
        public var hlcPhysicalNow: Int64
        public var localNodeCount: Int     // known peer nodes

        public init(clockSuspect: Bool = false, lastPanicResult: String = "—",
                    dbSizeBytes: Int64 = 0, nodeIDSuffix: String = "??",
                    hlcPhysicalNow: Int64 = 0, localNodeCount: Int = 0) {
            self.clockSuspect = clockSuspect
            self.lastPanicResult = lastPanicResult
            self.dbSizeBytes = dbSizeBytes
            self.nodeIDSuffix = nodeIDSuffix
            self.hlcPhysicalNow = hlcPhysicalNow
            self.localNodeCount = localNodeCount
        }
    }

    // MARK: Fields

    public var capturedAt: Date
    public var pipeline: Pipeline
    public var syncCursors: SyncCursors
    public var sources: [SourceState]
    public var system: System

    public init(
        capturedAt: Date = Date(),
        pipeline: Pipeline = .init(),
        syncCursors: SyncCursors = .init(),
        sources: [SourceState] = [],
        system: System = .init()
    ) {
        self.capturedAt = capturedAt
        self.pipeline = pipeline
        self.syncCursors = syncCursors
        self.sources = sources
        self.system = system
    }
}

// MARK: - DiagnosticsView

/// SwiftUI view displaying the current framework diagnostics.
///
/// The view receives a `DiagnosticsSnapshot` and renders it in sections.
/// The caller is responsible for snapshotting — the view is pure and
/// never accesses any actor directly.
public struct DiagnosticsView: View {
    public let snapshot: DiagnosticsSnapshot

    public init(snapshot: DiagnosticsSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                capturedHeader
                Divider().padding(.vertical, 4)
                pipelineSection
                Divider().padding(.vertical, 4)
                syncCursorsSection
                Divider().padding(.vertical, 4)
                sourcesSection
                Divider().padding(.vertical, 4)
                systemSection
            }
            .padding()
        }
        .navigationTitle("Diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Captured at header

    @ViewBuilder
    private var capturedHeader: some View {
        HStack {
            Text("Snapshotted at")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(snapshot.capturedAt, style: .time)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Pipeline

    @ViewBuilder
    private var pipelineSection: some View {
        DiagnosticSection(title: "Pipeline") {
            KeyValueRow("Status", snapshot.pipeline.isRunning ? "Running" : "Stopped")
                .foregroundColor(snapshot.pipeline.isRunning ? .green : .secondary)
            KeyValueRow("Vitals status", snapshot.pipeline.vitalsStatus.displayName)
                .foregroundColor(snapshot.pipeline.vitalsStatus.displayColor)
            Text("Presentation state only — not a clinical alert.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Sync cursors

    @ViewBuilder
    private var syncCursorsSection: some View {
        DiagnosticSection(title: "Sync Cursors (\(snapshot.syncCursors.perNode.count) node(s))") {
            if snapshot.syncCursors.perNode.isEmpty {
                Text("No peer nodes known")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(snapshot.syncCursors.perNode, id: \.nodeIDSuffix) { node in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Node …\(node.nodeIDSuffix)")
                            .font(.caption)
                            .fontWeight(.semibold)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading) {
                                Text("Pull samples")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(hlcDisplay(node.pullSamplesHLC))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            VStack(alignment: .leading) {
                                Text("Push samples")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(hlcDisplay(node.pushSamplesHLC))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            VStack(alignment: .leading) {
                                Text("Pull tombs")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(hlcDisplay(node.pullTombstonesHLC))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            VStack(alignment: .leading) {
                                Text("Push tombs")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(hlcDisplay(node.pushTombstonesHLC))
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        DiagnosticSection(title: "Sensor Sources") {
            if snapshot.sources.isEmpty {
                Text("No sources attached")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(snapshot.sources, id: \.name) { src in
                    HStack {
                        Circle()
                            .fill(src.isIdle ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(src.name)
                            .font(.caption)
                        Spacer()
                        if let sec = src.secondsSinceLastFrame {
                            Text("\(Int(sec))s ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("never")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - System

    @ViewBuilder
    private var systemSection: some View {
        DiagnosticSection(title: "System") {
            KeyValueRow("Node ID", "…\(snapshot.system.nodeIDSuffix)")
            KeyValueRow("Clock suspect", snapshot.system.clockSuspect ? "YES" : "no")
                .foregroundColor(snapshot.system.clockSuspect ? .red : .green)
            KeyValueRow("Local HLC", hlcDisplay(snapshot.system.hlcPhysicalNow))
            KeyValueRow("Known peers", "\(snapshot.system.localNodeCount)")
            KeyValueRow("Last panic", snapshot.system.lastPanicResult)
            KeyValueRow("DB size", formatBytes(snapshot.system.dbSizeBytes))
        }
    }

    // MARK: - Helpers

    private func hlcDisplay(_ physical: Int64) -> String {
        if physical == 0 { return "—" }
        let date = Date(timeIntervalSince1970: Double(physical) / 1000.0)
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "—" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Reusable section wrapper

private struct DiagnosticSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 2)
            content()
        }
        .padding(.vertical, 8)
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack {
            Text(key)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }
}

// MARK: - VitalsStatus display helpers

private extension VitalsStatus {
    var displayName: String {
        switch self {
        case .normal: return "Live"
        case .idle: return "Idle"
        }
    }

    var displayColor: Color {
        switch self {
        case .normal: return .green
        case .idle: return .secondary
        }
    }
}
