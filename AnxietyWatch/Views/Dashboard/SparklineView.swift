import SwiftUI

/// Normalized point for sparkline rendering. x and y are 0–1.
struct SparklinePoint {
    let x: Double
    let y: Double
}

/// Prepares HealthSample arrays into normalized points for sparkline rendering.
enum SparklineData {

    /// Convert samples into normalized 0–1 points.
    /// X: position between midnight and now. Y: inverted (0=max, 1=min) for
    /// natural chart rendering where higher values appear higher.
    static func points(
        from samples: [HealthSample],
        midnight: Date,
        now: Date
    ) -> [SparklinePoint] {
        guard !samples.isEmpty else { return [] }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let totalSeconds = now.timeIntervalSince(midnight)
        guard totalSeconds > 0 else { return [] }

        let values = sorted.map(\.value)
        let minVal = values.min()!
        let maxVal = values.max()!
        let range = maxVal - minVal

        return sorted.map { sample in
            let x = sample.timestamp.timeIntervalSince(midnight) / totalSeconds
            let y = range > 0 ? 1.0 - (sample.value - minVal) / range : 0.5
            return SparklinePoint(x: x.clamped(to: 0...1), y: y)
        }
    }

    /// Split samples into contiguous segments, breaking at gaps > threshold.
    /// Each segment is an array of normalized SparklinePoints.
    static func segments(
        from samples: [HealthSample],
        midnight: Date,
        now: Date,
        gapThresholdMinutes: Int = 120
    ) -> [[SparklinePoint]] {
        guard !samples.isEmpty else { return [] }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let allPoints = points(from: sorted, midnight: midnight, now: now)

        let gapSeconds = Double(gapThresholdMinutes) * 60
        var segments: [[SparklinePoint]] = []
        var current: [SparklinePoint] = []

        for (i, point) in allPoints.enumerated() {
            if i > 0 {
                let timeDelta = sorted[i].timestamp.timeIntervalSince(sorted[i - 1].timestamp)
                if timeDelta > gapSeconds {
                    if !current.isEmpty { segments.append(current) }
                    current = []
                }
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }

        return segments
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Intraday sparkline with gradient fill, gap handling, and current-value dot.
struct SparklineView: View {
    let segments: [[SparklinePoint]]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Canvas { context, size in
                for segment in segments {
                    guard segment.count >= 2 else {
                        // Single point: draw a dot
                        if let pt = segment.first {
                            let center = CGPoint(x: pt.x * w, y: pt.y * h)
                            let dot = Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
                            context.fill(dot, with: .color(color))
                        }
                        continue
                    }

                    // Line path
                    var linePath = Path()
                    linePath.move(to: CGPoint(x: segment[0].x * w, y: segment[0].y * h))
                    for pt in segment.dropFirst() {
                        linePath.addLine(to: CGPoint(x: pt.x * w, y: pt.y * h))
                    }
                    context.stroke(linePath, with: .color(color), lineWidth: 1.5)

                    // Fill path
                    var fillPath = linePath
                    fillPath.addLine(to: CGPoint(x: segment.last!.x * w, y: h))
                    fillPath.addLine(to: CGPoint(x: segment[0].x * w, y: h))
                    fillPath.closeSubpath()
                    context.fill(fillPath, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.25), color.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: h)
                    ))
                }

                // Current value dot on last point of last segment
                if let lastSeg = segments.last, let lastPt = lastSeg.last {
                    let center = CGPoint(x: lastPt.x * w, y: lastPt.y * h)
                    let dot = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(color))
                }
            }
        }
    }
}
