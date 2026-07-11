import CoreGraphics

/// Pure geometry for the watchOS Quick Log severity grid.
///
/// Ten circular severity targets on one screen (no scrolling), arranged in a
/// near-square 4×3 grid so the circles are as large as possible. The design
/// goal is panic-friendliness: during an anxiety or panic episode the user has
/// shaky hands and impaired focus, so every target must be visible at once and
/// large enough to hit without fine motor control. A 5-across grid caps the
/// circle at the column width (~40pt) and leaves the screen mostly empty;
/// fewer, wider columns make each circle bigger. Circles can't tile a screen
/// flush the way rectangles can, so the rows are spread to fill the height and
/// the final short row is centred.
///
/// Kept free of SwiftUI/WatchKit so the sizing math is isolated and testable.
struct QuickLogLayout {
    static let count = 10
    static let cols = 4
    /// Derived from `count`/`cols` so the height math and `rowsOfLevels()` can
    /// never disagree about how many rows the grid actually has.
    static let rows = (count + cols - 1) / cols
    static let spacing: CGFloat = 6

    /// Circle diameter — the largest circle that fits both the column width and
    /// the row height, so the circles are as big as the screen allows.
    let diameter: CGFloat
    /// Point size for the severity number, ~half the diameter so a heavy
    /// rounded digit fills the circle; `minimumScaleFactor` covers "10".
    let fontSize: CGFloat

    init(size: CGSize) {
        let byWidth = (size.width - Self.spacing * CGFloat(Self.cols - 1)) / CGFloat(Self.cols)
        let byHeight = (size.height - Self.spacing * CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
        diameter = max(0, min(byWidth, byHeight))
        fontSize = diameter * 0.5
    }

    /// Severity levels grouped into rows of at most `cols` (the last row is
    /// shorter and gets centred by the view). Pure so the row-chunking is
    /// testable independently of layout.
    static func rowsOfLevels() -> [[Int]] {
        stride(from: 1, through: count, by: cols).map { start in
            Array(start...min(start + cols - 1, count))
        }
    }
}
