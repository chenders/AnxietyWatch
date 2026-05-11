// AnxietyWatch/Views/Dashboard/HRVSessionCardView.swift
import SwiftData
import SwiftUI

/// Dashboard-level affordance for the Polar H10 BLE session. Coexists with
/// the Settings → Polar H10 entry — Settings is for management (pair /
/// unpair), this card is the quick-start lane the user sees on every app
/// open.
///
/// State machine:
/// - Not paired → no card (don't clutter the Dashboard for users without a
///   strap).
/// - Paired + idle → "Start HRV Session" CTA, plus last-session summary
///   if any.
/// - Connecting / recording → "Resume Live View" + Stop (subtle), plus the
///   live HR/RMSSD readouts so a glance at the Dashboard tells you the
///   session is healthy.
/// - Error / Bluetooth-* → inline label with the recovery hint already
///   matching the Pairing view copy.
struct HRVSessionCardView: View {
    let service: PolarHRMService
    @Binding var showingLiveSession: Bool
    /// Just the most recent completed Polar session — used for the
    /// "Last session" summary. Limited to one row so the Dashboard
    /// doesn't drag a growing history into memory on every render.
    /// Defined entirely via the FetchDescriptor below to keep the
    /// predicate/sort definition in one place.
    @Query private var pastSessions: [SensorSession]

    init(service: PolarHRMService, showingLiveSession: Binding<Bool>) {
        self.service = service
        self._showingLiveSession = showingLiveSession
        // Bind the source label to a local so the #Predicate macro can
        // capture it as a literal at compile time — referencing
        // PolarHRMService.sourceLabel directly inside the predicate isn't
        // supported, but capturing through a local works and still keeps a
        // single source of truth for the string.
        let polarSource = PolarHRMService.sourceLabel
        var descriptor = FetchDescriptor<SensorSession>(
            predicate: #Predicate<SensorSession> { $0.source == polarSource && $0.endTime != nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        self._pastSessions = Query(descriptor)
    }

    var body: some View {
        let state = service.state
        if !service.isPaired {
            // Empty — Settings is the discovery path for first-time pairing.
            EmptyView()
        } else {
            cardBody(for: state)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func cardBody(for state: PolarHRMState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(for: state)
            Divider()
            content(for: state)
        }
    }

    @ViewBuilder
    private func header(for state: PolarHRMState) -> some View {
        HStack {
            Label("Polar H10", systemImage: "heart.text.square.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            statusBadge(for: state.status)
        }
    }

    @ViewBuilder
    private func content(for state: PolarHRMState) -> some View {
        switch state.status {
        case .recording, .connecting:
            liveContent(for: state)
        case .bluetoothOff:
            inlineStatus(message: "Bluetooth is off. Enable it in iOS Settings to start a session.", color: .red)
        case .bluetoothUnauthorized:
            inlineStatus(message: "Allow Bluetooth permission in iOS Settings → Anxiety Watch.", color: .red)
        case .bluetoothUnsupported:
            inlineStatus(message: "Bluetooth not available on this device.", color: .secondary)
        case .error(let message):
            inlineStatus(message: message, color: .red)
            startButton(label: "Retry Start")
        default:
            idleContent()
        }
    }

    @ViewBuilder
    private func liveContent(for state: PolarHRMState) -> some View {
        HStack(spacing: 24) {
            metric(
                value: state.currentHR.map { "\($0)" } ?? "—",
                unit: "bpm",
                label: "Heart rate"
            )
            metric(
                value: state.lastMinuteRMSSD.map { String(format: "%.0f", $0) } ?? "—",
                unit: "ms",
                label: "RMSSD"
            )
            metric(
                value: formatElapsed(state.sessionElapsed),
                unit: "",
                label: "Elapsed"
            )
        }
        HStack {
            Button { showingLiveSession = true } label: {
                Label("Resume Live View", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(role: .destructive) {
                service.stopSession()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    @ViewBuilder
    private func idleContent() -> some View {
        if let recent = pastSessions.first {
            lastSessionSummary(recent)
        } else {
            Text("Wear the strap and tap Start to record high-fidelity HRV.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        startButton(label: "Start HRV Session")
    }

    @ViewBuilder
    private func lastSessionSummary(_ session: SensorSession) -> some View {
        let summary = parseSummary(session.summaryJSON)
        let durationLabel = formatSessionDuration(session)
        Text("Last session")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 24) {
            metric(value: summary.rmssdLabel, unit: "ms", label: "Avg RMSSD")
            metric(value: durationLabel, unit: "", label: "Duration")
            metric(value: summary.rrCountLabel, unit: "", label: "RR samples")
        }
    }

    @ViewBuilder
    private func startButton(label: String) -> some View {
        Button {
            service.startSession()
            // startSession can synchronously transition to a Bluetooth-off /
            // unauthorized / unsupported / error status if the preconditions
            // aren't met. Only present the live-session sheet when we
            // actually entered the connecting/recording flow — otherwise the
            // status badge + inline error already render the right thing on
            // the card, and the sheet would be a misleading dead-end.
            switch service.state.status {
            case .connecting, .recording:
                showingLiveSession = true
            default:
                break
            }
        } label: {
            Label(label, systemImage: "heart.text.square.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private func inlineStatus(message: String, color: Color) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func statusBadge(for status: PolarHRMState.Status) -> some View {
        let (text, color, icon): (String, Color, String) = {
            switch status {
            case .recording: return ("Recording", .green, "record.circle.fill")
            case .connecting: return ("Connecting…", .orange, "antenna.radiowaves.left.and.right")
            case .scanning: return ("Scanning…", .orange, "magnifyingglass")
            case .idle: return ("Idle", .secondary, "circle")
            case .bluetoothOff: return ("BT Off", .red, "antenna.radiowaves.left.and.right.slash")
            case .bluetoothUnauthorized: return ("Denied", .red, "lock.shield")
            case .bluetoothUnsupported: return ("Unavailable", .secondary, "antenna.radiowaves.left.and.right.slash")
            case .error: return ("Error", .red, "exclamationmark.triangle.fill")
            }
        }()
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func metric(value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private struct ParsedSummary {
        let rmssdLabel: String
        let rrCountLabel: String
    }

    private func parseSummary(_ json: String?) -> ParsedSummary {
        guard let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedSummary(rmssdLabel: "—", rrCountLabel: "—")
        }
        let rmssd = (obj["rmssdMean"] as? Double).flatMap { $0 > 0 ? String(format: "%.0f", $0) : nil } ?? "—"
        let rrCount: String
        if let count = obj["rrCount"] as? Int, count > 0 {
            rrCount = count >= 1000 ? "\(count / 1000)k" : "\(count)"
        } else {
            rrCount = "—"
        }
        return ParsedSummary(rmssdLabel: rmssd, rrCountLabel: rrCount)
    }

    private func formatSessionDuration(_ session: SensorSession) -> String {
        guard let end = session.endTime else { return "—" }
        return formatElapsed(end.timeIntervalSince(session.startTime))
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        if m > 0 {
            return String(format: "%dm %02ds", m, s)
        }
        return "\(s)s"
    }
}
