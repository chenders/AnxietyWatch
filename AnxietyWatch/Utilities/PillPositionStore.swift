import Foundation
import CoreGraphics
import SwiftUI

/// Persists the recording status pill's last user-dragged position
/// across app launches and clamps drag targets to keep the pill
/// reachable. Pure-function `clamp` so the view layer can ask "where
/// would this drag land after bounds enforcement" without keeping the
/// math in body-scope.
struct PillPositionStore {
    private let defaults: UserDefaults
    private let key = "recordingStatusPill.position.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loaded last-known position. Nil before the user has ever dragged
    /// the pill — the view falls back to its default top-center anchor
    /// in that case.
    func load() -> CGPoint? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredPoint.self, from: data).cgPoint
    }

    func save(_ point: CGPoint) {
        let stored = StoredPoint(x: Double(point.x), y: Double(point.y))
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }

    /// Pulls `position` inside the rect formed by `screen` minus
    /// `safeArea` insets minus `pillSize`. Safe-area-aware so the pill
    /// can't be dragged or restored under the notch, Dynamic Island,
    /// status bar, or home indicator — anywhere it would be partially
    /// obscured by system chrome. Defaults to `EdgeInsets()` (zero
    /// inset on all sides) for callers that pre-date the safe-area
    /// awareness; the existing test cases all use that default and
    /// still pass.
    ///
    /// Degenerate cases (pill wider/taller than the safe rect) pin to
    /// the safe-area top-leading so the pill stays at least partially
    /// visible rather than going negative.
    static func clamp(
        position: CGPoint,
        screen: CGSize,
        pillSize: CGSize,
        safeArea: EdgeInsets = EdgeInsets()
    ) -> CGPoint {
        let minX = safeArea.leading
        let minY = safeArea.top
        let maxX = max(minX, screen.width - safeArea.trailing - pillSize.width)
        let maxY = max(minY, screen.height - safeArea.bottom - pillSize.height)
        return CGPoint(
            x: min(max(minX, position.x), maxX),
            y: min(max(minY, position.y), maxY)
        )
    }

    // MARK: - Codable storage

    private struct StoredPoint: Codable {
        let x: Double
        let y: Double
        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }
}
