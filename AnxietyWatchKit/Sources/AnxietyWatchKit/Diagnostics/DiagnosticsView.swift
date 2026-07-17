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
        public var currentTier: AlertTier
        public var fusionOverall: Double
        public var fusionContributions: FusionContributions
        public var ringCounts: RingCounts
        public var isRunning: Bool
        public var lastGapEndMs: Int64?

        public var thresholds: CNSThresholds

        public init(
            currentTier: AlertTier = .normal,
            fusionOverall: Double = 0,
            fusionContributions: FusionContributions = .init(),
            ringCounts: RingCounts = .init(),
            isRunning: Bool = false,
            lastGapEndMs: Int64? = nil,
            thresholds: CNSThresholds = .init()
        ) {
            self.currentTier = currentTier
            self.fusionOverall = fusionOverall
            self.fusionContributions = fusionContributions
            self.ringCounts = ringCounts
            self.isRunning = isRunning
            self.lastGapEndMs = lastGapEndMs
            self.thresholds = thresholds
        }
    }

    public struct FusionContributions: Sendable, Equatable, Codable {
        public var hr: Double          // 0…1
        public var hrv: Double
        public var spo2: Double
        public var accel: Double
        public var breath: Double

        public init(hr: Double = 0, hrv: Double = 0, spo2: Double = 0,
                    accel: Double = 0, breath: Double = 0) {
            self.hr = hr; self.hrv = hrv; self.spo2 = spo2
            self.accel = accel; self.breath = breath
        }
    }

    public struct RingCounts: Sendable, Equatable, Codable {
        public var hr: Int; public var spo2: Int; public var hrv: Int; public var accel: Int

        public init(hr: Int = 0, spo2: Int = 0, hrv: Int = 0, accel: Int = 0) {
            self.hr = hr; self.spo2 = spo2; self.hrv = hrv; self.accel = accel
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
                fusionSection
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
            KeyValueRow("Alert tier", snapshot.pipeline.currentTier.displayName)
                .foregroundColor(snapshot.pipeline.currentTier.displayColor)
            if let gapMs = snapshot.pipeline.lastGapEndMs {
                KeyValueRow("Last data gap end", "\(gapMs / 1000)s ago")
                    .foregroundColor(.orange)
            } else {
                KeyValueRow("Last data gap", "none")
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Fusion score

    @ViewBuilder
    private var fusionSection: some View {
        DiagnosticSection(title: "Fusion Score") {
            HStack {
                Text(String(format: "%.1f%%", snapshot.pipeline.fusionOverall * 100))
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(riskColor(snapshot.pipeline.fusionOverall))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    contributionRow("HR",  snapshot.pipeline.fusionContributions.hr)
                    contributionRow("HRV", snapshot.pipeline.fusionContributions.hrv)
                    contributionRow("SpO₂", snapshot.pipeline.fusionContributions.spo2)
                    contributionRow("Accel", snapshot.pipeline.fusionContributions.accel)
                    contributionRow("Breath", snapshot.pipeline.fusionContributions.breath)
                }
            }

            Divider().padding(.vertical, 4)

            Text("Ring buffer depths")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.bottom, 2)

            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()),
                GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 8) {
                ringCountTile("HR", snapshot.pipeline.ringCounts.hr, capacity: 120)
                ringCountTile("SpO₂", snapshot.pipeline.ringCounts.spo2, capacity: 60)
                ringCountTile("HRV", snapshot.pipeline.ringCounts.hrv, capacity: 60)
                ringCountTile("Accel", snapshot.pipeline.ringCounts.accel, capacity: 200)
            }
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

    private func contributionRow(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func ringCountTile(_ label: String, _ count: Int, capacity: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("/\(capacity)")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.12))
        )
    }

    private func riskColor(_ score: Double) -> Color {
        switch score {
        case 0..<0.25: return .green
        case 0.25..<0.50: return .yellow
        case 0.50..<0.75: return .orange
        default: return .red
        }
    }

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

// MARK: - AlertTier display helpers

private extension AlertTier {
    var displayName: String {
        switch self {
        case .normal:   return "Normal"
        case .advisory: return "Advisory"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    var displayColor: Color {
        switch self {
        case .normal:   return .green
        case .advisory: return .yellow
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}
