#if DEBUG
import Testing
import Foundation
import CoreGraphics
import UIKit
@testable import AnxietyWatch

@Suite("DebugScreenCapture.compositeRects")
struct CompositeRectsTests {

    /// iPhone 17 Pro logical dimensions.
    private let chromeSize = CGSize(width: 393, height: 852)

    @Test("Mid-screen scrollview produces top + unfurled + bottom rects")
    func midScreenScrollview() {
        let scrollFrame = CGRect(x: 0, y: 60, width: 393, height: 700)
        let unfurled = CGSize(width: 393, height: 2500)

        let layout = ScreenCapturePipeline.compositeRects(
            chromeSize: chromeSize,
            scrollFrameInWindow: scrollFrame,
            unfurledSize: unfurled
        )

        let heightDelta = unfurled.height - scrollFrame.height
        #expect(abs(layout.canvasSize.height - (chromeSize.height + heightDelta)) < 0.5)
        #expect(abs(layout.topChromeRect.height - 60) < 0.5)
        #expect(abs(layout.unfurledRect.height - 2500) < 0.5)
        #expect(abs(layout.bottomChromeRect.height - 92) < 0.5)
    }

    @Test("Scrollview anchored at top — topChromeRect height is 0")
    func anchoredAtTop() {
        let scrollFrame = CGRect(x: 0, y: 0, width: 393, height: 800)
        let unfurled = CGSize(width: 393, height: 2000)

        let layout = ScreenCapturePipeline.compositeRects(
            chromeSize: chromeSize,
            scrollFrameInWindow: scrollFrame,
            unfurledSize: unfurled
        )

        #expect(abs(layout.topChromeRect.height) < 0.5)
        #expect(abs(layout.unfurledRect.minY) < 0.5)
    }

    @Test("Scrollview anchored at bottom — bottomChromeRect height is 0")
    func anchoredAtBottom() {
        let scrollFrame = CGRect(x: 0, y: 60, width: 393, height: 792)
        let unfurled = CGSize(width: 393, height: 2000)

        let layout = ScreenCapturePipeline.compositeRects(
            chromeSize: chromeSize,
            scrollFrameInWindow: scrollFrame,
            unfurledSize: unfurled
        )

        #expect(abs(layout.bottomChromeRect.height) < 0.5)
    }

    @Test("Unfurled no taller than scroll frame — chrome-only layout")
    func noOverflow() {
        let scrollFrame = CGRect(x: 0, y: 60, width: 393, height: 700)
        let unfurled = CGSize(width: 393, height: 600)

        let layout = ScreenCapturePipeline.compositeRects(
            chromeSize: chromeSize,
            scrollFrameInWindow: scrollFrame,
            unfurledSize: unfurled
        )

        #expect(abs(layout.canvasSize.height - chromeSize.height) < 0.5)
        #expect(abs(layout.unfurledRect.height) < 0.5)
    }

    @Test("Scrollview frame extends past window — clamped, no negative rects")
    func frameExceedsWindowBounds() {
        // A pathological scrollFrame whose maxY (= 60 + 900 = 960) exceeds
        // chromeSize.height (852) — can happen briefly during rotation or
        // sheet-dismiss before layoutIfNeeded settles.
        let scrollFrame = CGRect(x: 0, y: 60, width: 393, height: 900)
        let unfurled = CGSize(width: 393, height: 2500)

        let layout = ScreenCapturePipeline.compositeRects(
            chromeSize: chromeSize,
            scrollFrameInWindow: scrollFrame,
            unfurledSize: unfurled
        )

        #expect(layout.topChromeRect.height >= 0)
        #expect(layout.bottomChromeRect.height >= 0)
        #expect(layout.bottomChromeSourceRect.height >= 0)
        // The bottom chrome should be zero-height: the scrollview already
        // covers down to (and past) the window's bottom.
        #expect(abs(layout.bottomChromeRect.height) < 0.5)
        // Regression: canvas must accommodate the unfurled rect's full
        // height. Pre-fix this overflowed by ~108pt and was silently
        // clipped by UIGraphicsImageRenderer.
        #expect(layout.unfurledRect.maxY <= layout.canvasSize.height + 0.5)
    }
}

@Suite("DebugScreenCapture.debounceDecision")
struct DebounceDecisionTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_715_000_000)

    @Test("No prior fire — fires")
    func noLastFire() {
        let decision = ScreenCapturePipeline.debounceDecision(
            now: referenceDate,
            lastFire: nil,
            window: 1.5
        )
        #expect(decision == true)
    }

    @Test("Exactly at the window boundary — fires")
    func atBoundary() {
        let decision = ScreenCapturePipeline.debounceDecision(
            now: referenceDate.addingTimeInterval(1.5),
            lastFire: referenceDate,
            window: 1.5
        )
        #expect(decision == true)
    }

    @Test("Inside the debounce window — skips")
    func insideWindow() {
        let decision = ScreenCapturePipeline.debounceDecision(
            now: referenceDate.addingTimeInterval(0.5),
            lastFire: referenceDate,
            window: 1.5
        )
        #expect(decision == false)
    }

    @Test("Zero window — always fires")
    func zeroWindow() {
        let decision = ScreenCapturePipeline.debounceDecision(
            now: referenceDate.addingTimeInterval(0.001),
            lastFire: referenceDate,
            window: 0
        )
        #expect(decision == true)
    }
}

@Suite("DebugScreenCapture.selectScrollView")
struct SelectScrollViewTests {

    private func candidate(
        id: Int,
        depth: Int,
        contentHeight: CGFloat,
        boundsHeight: CGFloat = 700,
        insets: UIEdgeInsets = .zero,
        isInsidePill: Bool = false
    ) -> ScreenCapturePipeline.ScrollCandidate {
        ScreenCapturePipeline.ScrollCandidate(
            id: id,
            depth: depth,
            frameInWindow: CGRect(x: 0, y: 0, width: 393, height: boundsHeight),
            contentSize: CGSize(width: 393, height: contentHeight),
            adjustedContentInset: insets,
            isInsidePillOverlay: isInsidePill
        )
    }

    @Test("Two overflowing — picks deepest")
    func picksDeepest() {
        let result = ScreenCapturePipeline.selectScrollView(candidates: [
            candidate(id: 1, depth: 3, contentHeight: 2000),
            candidate(id: 2, depth: 7, contentHeight: 2500)
        ])
        #expect(result?.id == 2)
    }

    @Test("Deepest is pill-tagged — picks shallower non-pill")
    func skipsPill() {
        let result = ScreenCapturePipeline.selectScrollView(candidates: [
            candidate(id: 1, depth: 3, contentHeight: 2000),
            candidate(id: 2, depth: 7, contentHeight: 2500, isInsidePill: true)
        ])
        #expect(result?.id == 1)
    }

    @Test("No overflow — returns nil")
    func noOverflow() {
        let result = ScreenCapturePipeline.selectScrollView(candidates: [
            candidate(id: 1, depth: 3, contentHeight: 500, boundsHeight: 700)
        ])
        #expect(result == nil)
    }

    @Test("Empty candidates — returns nil")
    func empty() {
        let result = ScreenCapturePipeline.selectScrollView(candidates: [])
        #expect(result == nil)
    }

    @Test("Single overflowing — picks it")
    func singleOverflow() {
        let result = ScreenCapturePipeline.selectScrollView(candidates: [
            candidate(id: 1, depth: 3, contentHeight: 2000)
        ])
        #expect(result?.id == 1)
    }

    @Test("Degenerate visibleHeight (≤ 0) — skipped over a real candidate (regression)")
    func degenerateVisibleHeightSkipped() {
        // A transition-state scrollview with insets that exceed its
        // bounds (visibleHeight = 50 - 30 - 30 = -10) would have
        // `contentSize.height > visibleHeight` trivially true (anything
        // positive > a negative number), so the previous predicate
        // would have let it win the deepest-candidate selection over
        // the real overflowing scrollview at shallower depth — the
        // real one would then be skipped and the function would fall
        // back to chrome-only. The added `visibleHeight > 0` filter
        // excludes the degenerate candidate so the real one is picked.
        let result = ScreenCapturePipeline.selectScrollView(candidates: [
            candidate(
                id: 1, depth: 3,
                contentHeight: 2000,
                boundsHeight: 750,
                insets: UIEdgeInsets(top: 95, left: 0, bottom: 83, right: 0)
            ),
            candidate(
                id: 2, depth: 7,
                contentHeight: 10,
                boundsHeight: 50,
                insets: UIEdgeInsets(top: 30, left: 0, bottom: 30, right: 0)
            )
        ])
        #expect(result?.id == 1)
    }

    @Test("Overflows visible area but not raw bounds — selected (regression)")
    func overflowsVisibleButNotBounds() {
        // Form under a large nav bar + tab bar: bounds = 750pt,
        // insets = (95, 83) → visibleHeight = 572pt. Content of 700pt
        // exceeds visibleHeight but is below bounds.height. Previous
        // predicate would have skipped this (contentSize.height (700)
        // > frame.height (750) is false), falling back to chrome-only
        // and clipping content. The new predicate uses visibleHeight,
        // catching the case correctly.
        let result = ScreenCapturePipeline.selectScrollView(candidates: [
            candidate(
                id: 1, depth: 3,
                contentHeight: 700,
                boundsHeight: 750,
                insets: UIEdgeInsets(top: 95, left: 0, bottom: 83, right: 0)
            )
        ])
        #expect(result?.id == 1)
    }
}
#endif
