import SwiftUI

/// Last-N-readings bar chart for sparse metrics like VO₂ Max.
/// Each bar represents one reading, opacity fades for older readings.
struct RecentBarsView: View {
    let values: [Double]
    let color: Color
    let maxBars: Int

    init(values: [Double], color: Color, maxBars: Int = 7) {
        self.values = values
        self.color = color
        self.maxBars = maxBars
    }

    var body: some View {
        let displayValues = Array(values.suffix(maxBars))
        let maxVal = displayValues.max() ?? 1
        let minVal = displayValues.min() ?? 0
        let range = max(maxVal - minVal, 1)

        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(displayValues.enumerated()), id: \.offset) { index, value in
                    let normalizedHeight = 0.3 + 0.7 * (value - minVal) / range
                    let opacity = 0.4 + 0.6 * Double(index) / Double(max(displayValues.count - 1, 1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(opacity))
                        .frame(width: 8, height: 40 * normalizedHeight)
                }
            }
            .frame(height: 40, alignment: .bottom)

            Text("last \(displayValues.count) readings")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}
