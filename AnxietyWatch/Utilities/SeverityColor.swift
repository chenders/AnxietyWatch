import SwiftUI

extension Color {
    /// Maps anxiety severity (1-10) to a color.
    /// Used across Dashboard, Journal, Trends, and Medication views.
    static func severity(_ level: Int) -> Color {
        switch level {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
