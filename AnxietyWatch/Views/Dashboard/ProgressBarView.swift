import SwiftUI

/// Progress bar showing current value toward a goal.
/// Used for cumulative metrics like steps, calories, exercise minutes.
struct ProgressBarView: View {
    let current: Double
    let goal: Double
    let color: Color

    private var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(current / goal, 1.0)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.gradient)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(Int(fraction * 100))% of goal")
                Spacer()
                Text(goal.formatted(.number.precision(.fractionLength(0))))
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}
