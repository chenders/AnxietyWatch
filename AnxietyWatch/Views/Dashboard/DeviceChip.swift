import SwiftUI

/// Small source pill rendered in a metric card's header. The chip tells the
/// user which device produced the visible reading without taking real estate.
struct DeviceChip: View {
    enum Source: Sendable {
        case polar, watch, emay, iphone, manual

        var label: String {
            switch self {
            case .polar: "Polar"
            case .watch: "Watch"
            case .emay: "EMAY"
            case .iphone: "iPhone"
            case .manual: "Manual"
            }
        }

        var sfSymbol: String {
            switch self {
            case .polar: "heart.text.square.fill"
            case .watch: "applewatch"
            case .emay: "lungs.fill"
            case .iphone: "iphone"
            case .manual: "pencil"
            }
        }

        var tint: Color {
            switch self {
            case .polar: .blue
            case .watch: .gray
            case .emay: .green
            case .iphone: .secondary
            case .manual: .secondary
            }
        }
    }

    let source: Source

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.sfSymbol).font(.system(size: 9))
            Text(source.label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(source.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(source.tint.opacity(0.15), in: .capsule)
        .accessibilityLabel("Source: \(source.label)")
    }
}
