import Foundation
import SwiftUI
import Testing

@testable import AnxietyWatch

/// Tests for the pure `PillPositionStore` helper that clamps drag
/// offsets to safe bounds and round-trips through UserDefaults so the
/// pill's last position survives across app launches. View-layer
/// gesture handling is not covered here (no UI testing infrastructure
/// available); the math and persistence are.
@Suite("PillPositionStore")
struct PillPositionStoreTests {

    /// Stable suite name shared across all tests in this file.
    /// Earlier iterations used a fresh UUID per test, which avoided
    /// bleed but left a growing pile of `.plist` files in the test
    /// machine's preferences directory across runs. With a stable
    /// name and a `removePersistentDomain` call at the start of each
    /// test, the same single suite is reused — state is wiped before
    /// every test, and no new suites accumulate on disk.
    private static let testSuiteName = "PillPositionStoreTests"

    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: Self.testSuiteName)!
        suite.removePersistentDomain(forName: Self.testSuiteName)
        return suite
    }

    // MARK: - Clamping

    @Test("clamp leaves a position inside the screen untouched")
    func clampLeavesInsidePosition() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let inside = CGPoint(x: 100, y: 100)
        let clamped = PillPositionStore.clamp(position: inside, screen: screen, pillSize: pill)
        #expect(clamped == inside)
    }

    @Test("clamp pulls a position past the right edge back to the right edge")
    func clampPullsBackFromRight() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let outside = CGPoint(x: 500, y: 100)
        let clamped = PillPositionStore.clamp(position: outside, screen: screen, pillSize: pill)
        // Pill's right edge is its x + width; clamp ensures (x + width) <= screen.width
        #expect(clamped.x + pill.width <= screen.width)
        // Position should be exactly at the right edge.
        #expect(clamped.x == screen.width - pill.width)
        #expect(clamped.y == 100)
    }

    @Test("clamp pulls a negative x back to zero")
    func clampPullsBackFromLeft() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let outside = CGPoint(x: -50, y: 100)
        let clamped = PillPositionStore.clamp(position: outside, screen: screen, pillSize: pill)
        #expect(clamped.x == 0)
        #expect(clamped.y == 100)
    }

    @Test("clamp pulls a position past the bottom back to the bottom")
    func clampPullsBackFromBottom() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let outside = CGPoint(x: 100, y: 1000)
        let clamped = PillPositionStore.clamp(position: outside, screen: screen, pillSize: pill)
        #expect(clamped.y + pill.height <= screen.height)
        #expect(clamped.y == screen.height - pill.height)
    }

    @Test("clamp pulls a negative y back to zero")
    func clampPullsBackFromTop() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let outside = CGPoint(x: 100, y: -20)
        let clamped = PillPositionStore.clamp(position: outside, screen: screen, pillSize: pill)
        #expect(clamped.y == 0)
        #expect(clamped.x == 100)
    }

    @Test("clamp handles pill larger than screen by pinning to origin (degenerate case)")
    func clampDegenerate() {
        let screen = CGSize(width: 100, height: 100)
        let pill = CGSize(width: 200, height: 50) // wider than screen
        let pos = CGPoint(x: 50, y: 50)
        let clamped = PillPositionStore.clamp(position: pos, screen: screen, pillSize: pill)
        // When pill is wider than screen, max(0, screen.width - pill.width) is 0,
        // so x gets pinned to 0 rather than going negative.
        #expect(clamped.x == 0)
    }

    // MARK: - Safe-area-aware clamping

    @Test("clamp respects safeArea.top (pill can't slide under the notch/status bar)")
    func clampRespectsTopInset() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let safeArea = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let outside = CGPoint(x: 100, y: 10) // attempt to slide under the notch
        let clamped = PillPositionStore.clamp(
            position: outside,
            screen: screen,
            pillSize: pill,
            safeArea: safeArea
        )
        #expect(clamped.y == safeArea.top)
    }

    @Test("clamp respects safeArea.bottom (pill can't slide under the home indicator)")
    func clampRespectsBottomInset() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let safeArea = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let outside = CGPoint(x: 100, y: 1000)
        let clamped = PillPositionStore.clamp(
            position: outside,
            screen: screen,
            pillSize: pill,
            safeArea: safeArea
        )
        #expect(clamped.y + pill.height <= screen.height - safeArea.bottom)
        #expect(clamped.y == screen.height - safeArea.bottom - pill.height)
    }

    @Test("clamp respects safeArea.leading/.trailing on landscape devices with side insets")
    func clampRespectsHorizontalInsets() {
        let screen = CGSize(width: 844, height: 390)
        let pill = CGSize(width: 160, height: 36)
        // Landscape iPhone: notch/Dynamic Island on the side, ~50pt inset.
        let safeArea = EdgeInsets(top: 0, leading: 50, bottom: 21, trailing: 50)
        let outsideLeft = CGPoint(x: 10, y: 100)
        let clampedLeft = PillPositionStore.clamp(
            position: outsideLeft,
            screen: screen,
            pillSize: pill,
            safeArea: safeArea
        )
        #expect(clampedLeft.x == safeArea.leading)

        let outsideRight = CGPoint(x: 900, y: 100)
        let clampedRight = PillPositionStore.clamp(
            position: outsideRight,
            screen: screen,
            pillSize: pill,
            safeArea: safeArea
        )
        #expect(clampedRight.x == screen.width - safeArea.trailing - pill.width)
    }

    @Test("clamp with .zero safe area matches the pre-safe-area behavior")
    func clampZeroSafeAreaMatchesOldBehavior() {
        let screen = CGSize(width: 390, height: 844)
        let pill = CGSize(width: 160, height: 36)
        let pos = CGPoint(x: 100, y: 100)
        let withoutInset = PillPositionStore.clamp(position: pos, screen: screen, pillSize: pill)
        let withZeroInset = PillPositionStore.clamp(
            position: pos,
            screen: screen,
            pillSize: pill,
            safeArea: EdgeInsets()
        )
        #expect(withoutInset == withZeroInset)
    }

    // MARK: - Persistence round-trip

    @Test("round-trips a position through UserDefaults")
    func roundTrip() {
        let defaults = makeDefaults()
        let store = PillPositionStore(defaults: defaults)
        let saved = CGPoint(x: 123, y: 456)
        store.save(saved)
        #expect(store.load() == saved)
    }

    @Test("returns nil from load when no position has been saved")
    func loadNilWhenMissing() {
        let defaults = makeDefaults()
        let store = PillPositionStore(defaults: defaults)
        #expect(store.load() == nil)
    }

    @Test("overwrites a previously-saved position")
    func overwrites() {
        let defaults = makeDefaults()
        let store = PillPositionStore(defaults: defaults)
        store.save(CGPoint(x: 1, y: 2))
        store.save(CGPoint(x: 100, y: 200))
        #expect(store.load() == CGPoint(x: 100, y: 200))
    }
}
