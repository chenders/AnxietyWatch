import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity widget for an in-progress Polar H10 session. Renders
/// on the Lock Screen and in the Dynamic Island. Time-since-session-
/// start ticks via SwiftUI's `Text(timerInterval:)` so the system
/// updates the clock display without us pushing per-second activity
/// updates — only HR and status changes drive cross-process updates
/// (subject to `LiveActivityUpdateThrottle`).
struct HRVRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HRVRecordingActivityAttributes.self) { context in
            // Lock Screen + banner.
            lockScreenView(context: context)
                .activitySystemActionForegroundColor(.primary)
                // Tints the Live Activity surface — most importantly,
                // it propagates through to the status-bar time-pill on
                // non-Dynamic-Island devices. Red while recording,
                // orange while connecting, matching the in-app pill's
                // status dot and the Dynamic Island keylineTint. Apple
                // Maps gets its blue pill the same way; Music gets red;
                // we get a recognizable AnxietyWatch tint instead of a
                // generic system color.
                //
                // Solid color, not `.opacity(...)` — the system applies
                // its own blending against the Lock Screen material and
                // the status-bar pill chrome, so pre-blended values
                // render as nearly-invisible noise. Use the saturated
                // hue here; the system decides how to blend.
                .activityBackgroundTint(context.state.isLive ? .red : .orange)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — appears on long-press of the Dynamic
                // Island. Four regions; we use leading + trailing
                // for status + HR and bottom for the elapsed timer.
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context: context)
                }
            } compactLeading: {
                // Small dot, red while recording / orange while connecting.
                Circle()
                    .fill(context.state.isLive ? Color.red : Color.orange)
                    .frame(width: 8, height: 8)
            } compactTrailing: {
                // HR or em-dash placeholder; small enough to fit.
                Text(context.state.currentHRBPM.map { "\($0)" } ?? "—")
                    .font(.caption.monospacedDigit())
            } minimal: {
                // Just the HR; the activity itself is the indicator
                // that something is happening.
                Text(context.state.currentHRBPM.map { "\($0)" } ?? "—")
                    .font(.caption2.monospacedDigit())
            }
            .keylineTint(context.state.isLive ? .red : .orange)
        }
    }

    // MARK: - Lock Screen

    private func lockScreenView(context: ActivityViewContext<HRVRecordingActivityAttributes>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            statusBadge(isLive: context.state.isLive)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.statusText)
                    .font(.headline)
                // While the session is still establishing the Bluetooth
                // connection, the elapsed timer is paradoxical (a clock
                // running alongside "Connecting" status confuses users
                // into thinking they've started recording). Show
                // "Starting…" instead until isLive flips true.
                if context.state.isLive {
                    HStack(spacing: 8) {
                        Text(timerInterval: context.attributes.sessionStartedAt...Date.distantFuture,
                             countsDown: false)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        Text(hrText(context.state.currentHRBPM))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Starting…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Dynamic Island Expanded

    private func expandedLeading(context: ActivityViewContext<HRVRecordingActivityAttributes>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(context.state.isLive ? Color.red : Color.orange)
                .frame(width: 10, height: 10)
            Text(context.state.statusText)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func expandedTrailing(context: ActivityViewContext<HRVRecordingActivityAttributes>) -> some View {
        Text(hrText(context.state.currentHRBPM))
            .font(.headline.monospacedDigit())
    }

    @ViewBuilder
    private func expandedBottom(context: ActivityViewContext<HRVRecordingActivityAttributes>) -> some View {
        // Same isLive gate as the Lock Screen — no timer while still
        // connecting; users should see "Starting…" instead of a
        // confusingly-running clock.
        if context.state.isLive {
            HStack {
                Image(systemName: "stopwatch")
                    .foregroundStyle(.secondary)
                Text(timerInterval: context.attributes.sessionStartedAt...Date.distantFuture,
                     countsDown: false)
                    .font(.body.monospacedDigit())
                Spacer()
            }
            .padding(.top, 4)
        } else {
            HStack {
                Image(systemName: "wifi.router")
                    .foregroundStyle(.secondary)
                Text("Starting…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func statusBadge(isLive: Bool) -> some View {
        ZStack {
            Circle()
                .fill((isLive ? Color.red : Color.orange).opacity(0.18))
                .frame(width: 36, height: 36)
            Circle()
                .fill(isLive ? Color.red : Color.orange)
                .frame(width: 12, height: 12)
        }
    }

    private func hrText(_ bpm: Int?) -> String {
        guard let bpm else { return "— BPM" }
        return "\(bpm) BPM"
    }
}
