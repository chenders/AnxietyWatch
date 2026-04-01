import SwiftUI

extension Color {
    /// Maps anxiety severity (1-10) to a color across 5 bands:
    /// 1-2 calm, 3-4 mild, 5-6 moderate, 7-8 high, 9-10 crisis.
    /// Used across Dashboard, Journal, Trends, Watch, and Medication views.
    static func severity(_ level: Int) -> Color {
        switch level {
        case 1...2: return .green
        case 3...4: return .yellow
        case 5...6: return .orange
        case 7...8: return .red
        default: return Color(red: 0.6, green: 0.0, blue: 0.0) // dark red
        }
    }

    /// Short label describing the severity band.
    static func severityLabel(_ level: Int) -> String {
        switch level {
        case 1...2: return "Calm"
        case 3...4: return "Mild"
        case 5...6: return "Moderate"
        case 7...8: return "High"
        default: return "Crisis"
        }
    }
}
