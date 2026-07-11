// AnxietyWatchTests/QuickLogLayoutTests.swift
import CoreGraphics
import Testing

@testable import AnxietyWatch

/// Covers the watchOS Quick Log grid geometry. The layout exists to keep every
/// severity target visible and large enough to hit during a panic episode, so
/// the properties worth pinning down are: all ten levels are reachable, they
/// stay in order, and the circles never exceed the space available.
struct QuickLogLayoutTests {

    // MARK: - Row chunking

    @Test("Rows cover levels 1...10 exactly once, in order")
    func rowsCoverEveryLevelInOrder() {
        let flattened = QuickLogLayout.rowsOfLevels().flatMap { $0 }
        #expect(flattened == Array(1...QuickLogLayout.count))
    }

    @Test("Rows chunk 10 levels into 4+4+2 — the short row is last, not first")
    func rowChunkingSplitsFourFourTwo() {
        let rows = QuickLogLayout.rowsOfLevels()
        #expect(rows.count == QuickLogLayout.rows)
        #expect(rows.map(\.count) == [4, 4, 2])
        // The severe end (9, 10) lands on the final row; a leading short row
        // would push 1 and 2 off on their own and reorder the scale.
        #expect(rows.last == [9, 10])
        #expect(rows.first == [1, 2, 3, 4])
    }

    @Test("No row exceeds the column count")
    func noRowOverflowsColumns() {
        for row in QuickLogLayout.rowsOfLevels() {
            #expect(row.count <= QuickLogLayout.cols)
        }
    }

    @Test("Declared row count matches the rows actually produced")
    func declaredRowCountMatchesChunking() {
        // `rows` is derived from count/cols; if the two ever disagree the
        // height math would size circles for a grid that isn't rendered.
        #expect(QuickLogLayout.rowsOfLevels().count == QuickLogLayout.rows)
    }

    // MARK: - Diameter

    @Test("Diameter is bounded by the narrower of column width and row height")
    func diameterTakesTheBindingConstraint() {
        // 46mm-ish content area: width is the binding constraint here.
        let layout = QuickLogLayout(size: CGSize(width: 200, height: 240))
        let byWidth = (200 - QuickLogLayout.spacing * CGFloat(QuickLogLayout.cols - 1))
            / CGFloat(QuickLogLayout.cols)
        let byHeight = (240 - QuickLogLayout.spacing * CGFloat(QuickLogLayout.rows - 1))
            / CGFloat(QuickLogLayout.rows)
        #expect(abs(layout.diameter - min(byWidth, byHeight)) < 0.001)
    }

    @Test("Circles fit the available width and height without overlapping")
    func circlesFitWithinBounds() {
        for size in [CGSize(width: 200, height: 240),
                     CGSize(width: 176, height: 210),
                     CGSize(width: 220, height: 260)] {
            let layout = QuickLogLayout(size: size)
            let usedWidth = layout.diameter * CGFloat(QuickLogLayout.cols)
                + QuickLogLayout.spacing * CGFloat(QuickLogLayout.cols - 1)
            let usedHeight = layout.diameter * CGFloat(QuickLogLayout.rows)
                + QuickLogLayout.spacing * CGFloat(QuickLogLayout.rows - 1)
            #expect(usedWidth <= size.width + 0.001)
            #expect(usedHeight <= size.height + 0.001)
        }
    }

    @Test("A degenerate zero size clamps to zero rather than going negative")
    func zeroSizeClampsToZero() {
        // Spacing exceeds the available space here, so the raw math is negative.
        let layout = QuickLogLayout(size: .zero)
        #expect(layout.diameter == 0)
        #expect(layout.fontSize == 0)
    }

    // MARK: - Font

    @Test("Font size scales with the diameter so the digit fills the circle")
    func fontScalesWithDiameter() {
        let layout = QuickLogLayout(size: CGSize(width: 200, height: 240))
        #expect(abs(layout.fontSize - layout.diameter * 0.5) < 0.001)
        #expect(layout.fontSize > 0)
    }

    @Test("A larger face yields larger circles")
    func largerFaceYieldsLargerCircles() {
        let small = QuickLogLayout(size: CGSize(width: 176, height: 210))
        let large = QuickLogLayout(size: CGSize(width: 220, height: 260))
        #expect(large.diameter > small.diameter)
    }
}
