# Debug Full-Screen Scrolling Screenshot Capture — Design

**Date:** 2026-05-13
**Branch:** `feat/debug-screen-capture`
**Goal:** Provide a DEBUG-build-only manual capture tool: shake the phone, and a full-length PNG of the current iOS screen (chrome + unfurled scroll content) lands in the Photos library. Used by the developer for manual debugging and visual regression spotting. Zero footprint in release builds.

## Why

When iterating on UI changes (recent examples: liquid-glass TabView in iOS 18+, the draggable `RecordingStatusPill`, the multi-card Trends layout), the visible viewport is rarely enough to evaluate a screen. The native iOS screenshot (`Side+VolUp`) captures one viewport's worth and leaves the rest implicit — so a Dashboard with eight chart cards stacked vertically becomes eight separate screenshots taped together. Apple's "Full Page" capture is gated to Safari, Mail, Notes, and a handful of system apps; third-party apps have no equivalent.

`pymobiledevice3 developer screenshot` (the existing fallback documented in user memory) is also single-viewport — same problem.

This feature gives the developer a single shake → single PNG containing the entire screen, top to bottom.

## Decisions

These were settled during brainstorming on 2026-05-13. Each was a deliberate choice between named alternatives.

| Decision | Choice | Rejected alternatives | Why |
|---|---|---|---|
| Primary use case | **Manual debugging / regression catching** | Agentic loop visibility; release artifacts; UI snapshot testing | A personal debug tool, not a CI/release pipeline. |
| Trigger | **Physical shake gesture** | Three-finger long-press; floating debug button; settings menu button; sim-only keyboard shortcut | Works equally on a real iPhone and in the simulator; low UI footprint; false-fire cost is "an extra PNG to delete." |
| Destination | **Photos library** | Files app; share sheet; sim-vs-device split | Most accessible — review on phone, AirDrop to Mac. Requires `NSPhotoLibraryAddUsageDescription`. The permission string lives in `Info.plist` (always present), but the call site is `#if DEBUG`, so the prompt only ever fires in debug builds. |
| Capture mechanism | **Scroll-and-stitch via `drawHierarchy` at viewport size** | Bounds-resize + single-pass `drawHierarchy`; SwiftUI `ImageRenderer` per-view | The original design called for bounds-resize + single-pass render, but real-device testing surfaced `Render server returned error for view … SwiftUI.HostingScrollView` and produced empty/black unfurled regions. SwiftUI's `HostingScrollView` is layered on `UIScrollView` but its content is sized by SwiftUI's geometry resolver, not UIKit bounds — mutating `bounds.size` produces an inconsistent layer state the render server rejects. Scroll-and-stitch (set `contentOffset`, snapshot natural viewport, repeat) avoids the bug, uses the same render path the system's native screenshot does, and as a bonus materializes lazy `List` / `LazyVStack` rows as they enter the viewport. |
| Composition | **Full window with chrome + unfurled scroll content in place** | Scroll content only (no chrome); stacked viewport-above-unfurled | The nav-bar title is the single most useful piece of context when reviewing PNGs days later. Status bar and tab bar are also kept. The recording pill is omitted (clutter). |
| Failure feedback | **Silent log + haptic only** | Alert; toast; banner | An alert mid-debug-flow defeats the purpose of capturing what's on screen. Haptic (success vs error) + `os_log` is enough; Photos confirms success on its own. |
| Debounce | **1.5 s** | None; 500 ms; 3 s | The iPhone's accelerometer can double-fire on a vigorous shake. 1.5 s blocks the double-fire without being annoying when the user actually wants two captures in a row. |

## Scope

**In scope:**
- iOS app (`AnxietyWatch` target) only.
- DEBUG configurations only — every line of new code is `#if DEBUG`-fenced.
- Captures the topmost presented view (sheets, fullScreenCovers included by default).
- Captures the deepest visible `UIScrollView` with `contentSize.height > visibleHeight` (where `visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom`), ignoring any scrollview inside the recording pill overlay. Using `visibleHeight` rather than raw bounds catches Forms / Lists under nav bar + tab bar overlays where content overflows the visible area but not the raw bounds.
- Falls back to capturing the window chrome alone when no overflowing scrollview is found.
- Excludes the draggable `RecordingStatusPill` from the rendered output (temporarily hidden during capture, restored after).

**Out of scope:**
- watchOS (`AnxietyWatch Watch App` target). WatchKit has no `motionEnded`, and Digital Crown screenshots are already built in.
- (Originally: capturing lazy-`List` rows that haven't been materialized. The scroll-and-stitch approach implemented in real-device-bug fix now scrolls through and materializes them automatically, so this is no longer a limitation.)
- Multi-screen "snapshot every tab" automated flow.
- Capturing accessibility-overlay state, voice control indicators, or any other system overlays — those are part of `UIScreen`-level capture which we deliberately bypass to keep code in DEBUG fences.
- Release-build telemetry, opt-in flags, or any user-visible setting.

## Architecture

### Files

```
AnxietyWatch/
├── Utilities/
│   └── DebugScreenCapture.swift     ← NEW (entire file under #if DEBUG)
├── Views/Common/
│   └── RecordingStatusPill.swift    ← MODIFY: accessibilityIdentifier + typed constant
├── App/
│   └── ContentView.swift            ← MODIFY: one-line .modifier under #if DEBUG
└── Info.plist                       ← ADD: NSPhotoLibraryAddUsageDescription + NSPhotoLibraryUsageDescription
AnxietyWatchTests/
└── DebugScreenCaptureTests.swift    ← NEW (tests pure helpers; also #if DEBUG so they don't run in release-build CI test passes)
```

### Components inside `DebugScreenCapture.swift`

| Component | Type | Role |
|---|---|---|
| `Notification.Name.userDidShake` | static | Notification posted on shake; consumed by `_ShakeListener`. |
| `ShakeResponderRepresentable` | `UIViewControllerRepresentable` | Hosts a tiny `UIViewController` (private subclass `_ShakeRespondingViewController`) that becomes first responder on `viewDidAppear`, overrides `motionEnded(_:with:)` for `.motionShake`, and posts `userDidShake`. Zero visual footprint. |
| `DebugShakeCapture` | `ViewModifier` | Public modifier applied at `ContentView` level. Returns `content.background(_ShakeListener())` — note the modifier itself owns NO `@State`, so it cannot cascade-invalidate `ContentView`. |
| `_ShakeListener` | private `View` | Owns `@State var lastFireTime: Date?` and `ShakeResponderRepresentable`. Reacts to the notification via `.onReceive`, invokes `runCapturePipeline()`. This is the re-render scope when state changes — isolated from the tab tree. |
| `ScreenCapturePipeline` | namespace `enum` | Pure-where-possible helpers: `findTopmostScrollView`, `renderChromeImage`, `renderUnfurledScrollContent`, `compositeRects`, `selectScrollView`, `debounceDecision`. |
| `PhotosWriter` | namespace `enum` | Single function `save(_ image: UIImage) async throws` wrapping `PHPhotoLibrary.shared().performChanges`. |

### Why `_ShakeListener` exists as a separate View

This is critical and called out in `CLAUDE.md`'s pitfall list ("`@Observable` reads at App / WindowGroup scope"). The same principle applies to `@State` in a `ViewModifier`. If the modifier itself owned `@State var lastFireTime`, every state change would invalidate `ContentView` and re-render every tab.

By making the modifier a thin `content.background(_ShakeListener())` wrapper and putting all `@State` and observation inside `_ShakeListener`, state changes only re-render `_ShakeListener` itself — a 0×0 invisible View. ContentView is untouched.

### What does not change

- `RecordingStatusPill` gets one new line: `.accessibilityIdentifier("debug-recording-pill")` so the capture pipeline can find it for the hide-during-capture step. SwiftUI propagates the identifier to the resolved UIView, which we look up via BFS in the capture pipeline. No behavioral or visual change to the pill. If the identifier resolves to nil (e.g., pill not currently on screen, or future SwiftUI changes break the propagation), the hide-step is a no-op (pill appears in PNG, no crash).
- `PillPositionStore` is not touched.
- No changes to `AnxietyWatchApp` (no AppDelegate, no scene delegate). The shake responder is wired entirely through SwiftUI.
- No changes to any model, service, sync code, or watch app.

## Data flow

```
[User shakes the device]
        │
        ▼
_ShakeRespondingViewController.motionEnded(.motionShake, ...)
        │
        ▼
NotificationCenter.post(.userDidShake)
        │
        ▼
_ShakeListener.onReceive {
        │
        ▼
   debounceDecision(now: .now, lastFire: lastFireTime, window: 1.5s)
        │
        ├──[skip]──► return (no haptic)
        │
        ▼ [fire]
   lastFireTime = .now
   Task { await runCapturePipeline() }
}

runCapturePipeline:
   1. Resolve keyWindow (UIApplication.shared.connectedScenes → foregroundActive → keyWindow)
   2. Walk presentedViewController chain → take topmost VC's view as root
   3. BFS root for UIScrollView candidates; collect (scrollView, frameInWindow, contentSize, adjustedContentInset, isInsidePillOverlay) tuples
   4. selectScrollView(candidates:) → pick deepest non-pill scrollview with `contentSize.height > visibleHeight` (visibleHeight = bounds.height − insets.top − insets.bottom); nil if none
   5. Find pillView by accessibilityIdentifier; record pillOriginallyHidden
   6. pillView?.isHidden = true; defer pillView?.isHidden = pillOriginallyHidden
   7. keyWindow.layoutIfNeeded()
   8. Capture chrome image (UIGraphicsImageRenderer over keyWindow.bounds, drawHierarchy afterScreenUpdates: true)
   9. If scrollView != nil AND contentSize.height ≤ maxUnfurledHeight:
        a. Snapshot scrollView.contentOffset; defer { restore it }
        b. Allocate canvas of (visibleContentFrame.width × contentSize.height) as a CGBitmapContext; push into UIKit graphics stack with a flipped Y so we can draw in UIKit-style point coords
        c. minOffsetY = −insets.top; maxOffsetY = contentSize.height − visibleHeight − insets.top
        d. For canvasY in 0..contentSize.height step visibleHeight:
             - desiredOffsetY = minOffsetY + canvasY; actualOffsetY = min(desiredOffsetY, maxOffsetY)
             - scrollView.contentOffset = (x, actualOffsetY); layoutIfNeeded()
             - `await Task.sleep(50ms)` so SwiftUI's lazy content (LazyVStack/Form/List) has time to materialize for the new offset
             - Snapshot the WINDOW (not the scroll) via window.drawHierarchy; SwiftUI HostingScrollView's own drawHierarchy intermittently fails ("Render server returned error"), but window snapshots work reliably
             - Crop the window snapshot to the visible scroll region: `visibleInWindow.scaled(by: scale).integral.intersection(cgImageBounds)`
             - Draw the cropped slice into the bitmap context at canvas y = actualOffsetY + insets.top
        e. Pop UIKit context; produce final unfurled image from the bitmap context
        f. Compute compositeRects against the visibleContentFrame; composite full chrome (background, with systemBackground fill behind for any uncovered gutters) + unfurled at unfurledRect + shifted-bottom chrome
      Else if scrollView == nil OR cap exceeded: final image is chrome alone (cap case logs a warning)
  10. await PhotosWriter.save(finalImage)
        - PNG-encode image off main actor (Task.detached)
        - Write to tmp file
        - PHAssetCreationRequest.forAsset().addResource(.photo, fileURL:, shouldMoveFile: true)
  11. Success → UINotificationFeedbackGenerator().notificationOccurred(.success)
      Failure → .error + os_log via existing Logging subsystem
```

## Composite math

`compositeRects(chromeSize: CGSize, scrollFrameInWindow: CGRect, unfurledSize: CGSize)` returns:

```swift
struct CompositeLayout {
    let canvasSize: CGSize
    let topChromeRect: CGRect          // in canvas
    let topChromeSourceRect: CGRect    // in chrome image
    let unfurledRect: CGRect           // in canvas
    let bottomChromeRect: CGRect       // in canvas
    let bottomChromeSourceRect: CGRect // in chrome image
}
```

Algorithm:

```
heightDelta   = unfurledSize.height - scrollFrameInWindow.height
canvasHeight  = chromeSize.height + heightDelta  (only if heightDelta > 0; else canvas == chrome)

topChromeSourceRect    = (0, 0, chromeSize.width, scrollFrameInWindow.minY)
topChromeRect          = same coords in canvas (top corner anchored)
unfurledRect           = (scrollFrameInWindow.minX, scrollFrameInWindow.minY, scrollFrameInWindow.width, unfurledSize.height)
bottomChromeSourceRect = (0, scrollFrameInWindow.maxY, chromeSize.width, chromeSize.height - scrollFrameInWindow.maxY)
bottomChromeRect       = (0, scrollFrameInWindow.maxY + heightDelta, ...same size)
```

Edge cases the function handles:
- `heightDelta ≤ 0` → return chrome-only layout (canvas == chrome bounds, unfurled rect zero, treat as fallback).
- `scrollFrameInWindow.minY ≤ 0` → topChromeRect height is 0 (no nav bar above).
- `scrollFrameInWindow.maxY ≥ chromeSize.height` → bottomChromeRect height is 0 (no tab bar below).
- `scrollFrameInWindow.width != chromeSize.width` → unfurled is drawn at its captured rect; the chrome image underneath shows through on the left/right gutters. This case is theoretical on standard iOS portrait layouts where the scrollview spans the full window width, but the rect math handles it without a special case.

## Error handling & edge cases

1. **Mid-capture interrupt (backgrounding, rotation).** `defer` block restores the scrollview's original `contentOffset` regardless of how the function exits. (The scroll-and-stitch implementation only mutates `contentOffset` — no longer touches `bounds` or `isScrollEnabled` — so that's the only state needing restore.) Not unit-tested because it requires synthesizing a live UIScrollView; the `defer` placement is verified by inspection in code review.
2. **Photos permission denied.** First-shake-after-install prompts the user. If denied, `PHPhotoLibrary.performChanges` rejects with `PHPhotosError.notAuthorized`. We emit `.error` haptic and `os_log` via `Log.debugScreenCapture` (subsystem: the app's `Bundle.main.bundleIdentifier`, category: `debug-screen-capture`). No alert. To re-prompt, user goes to Settings → AnxietyWatch → Photos.
3. **`@State` cascade at ContentView scope.** Prevented by the `_ShakeListener`-owns-state pattern (see Architecture > "Why `_ShakeListener` exists").
4. **No overflowing scrollview.** Falls back to chrome-only capture. No error.
5. **Pill not findable.** Hide-step is a no-op. Pill appears in PNG (acceptable degradation).
6. **Sheet over sheet.** `presentedViewController` chain walk handles arbitrary nesting.
7. **Animation mid-capture.** `drawHierarchy(... afterScreenUpdates: true)` forces a layout pass before rendering; captured image reflects post-animation state.
8. **iOS 26 layout cascade risks.** Designed against the `CLAUDE.md` pitfall list: `ShakeResponderRepresentable` is not `@Observable`; `.onReceive` is scoped to `_ShakeListener`; the modifier itself owns no state. The implementation plan includes an explicit verification step (pre-PR review pass) to confirm.
9. **Concurrent shakes during capture.** Debounce prevents re-entry. The capture pipeline runs in a single `Task` whose continuation is awaited; the 1.5 s window covers typical capture duration (200–600 ms on a long Dashboard scrollview).

## Testing

### Pure helpers (Swift Testing, `@Test` macro)

**`compositeRects(chromeSize:scrollFrameInWindow:unfurledSize:)`**
- Mid-screen scrollview between nav bar and tab bar → top + unfurled + bottom rects all non-zero; canvas height = chrome + (unfurled - scrollFrame).
- Scrollview anchored at top (minY == 0) → topChromeRect height is 0.
- Scrollview anchored at bottom (maxY == chrome.height) → bottomChromeRect height is 0.
- `unfurledSize.height ≤ scrollFrameInWindow.height` → returns chrome-only layout.
- Float assertions use `abs(actual - expected) < 0.5` (sub-pixel epsilon per `CLAUDE.md` Common Pitfalls).

**`debounceDecision(now:lastFire:window:)`**
- `lastFire == nil` → fire.
- `now - lastFire == window` (boundary) → fire.
- `now - lastFire < window` → skip.
- `window == 0` → always fire (sanity check).

**`selectScrollView(candidates:)`** where each candidate is `(id: Int, depth: Int, frameInWindow: CGRect, contentSize: CGSize, isInsidePillOverlay: Bool)`
- Two overflowing scrollviews, neither pill-tagged → returns deepest (largest depth).
- Two overflowing scrollviews, deepest is pill-tagged → returns shallower one.
- One non-overflowing scrollview → returns nil.
- Empty candidates → returns nil.
- Single overflowing scrollview → returns it.

### Manual verification (lives in PR description checklist)

1. Shake on Dashboard tab (long scrollview of chart cards) → PNG contains full stack + nav title + tab bar.
2. Shake on Settings tab (Form) → PNG contains all form rows.
3. Shake on AddJournalEntry sheet → PNG contains the sheet's full content; backing tab is occluded by sheet (correct).
4. Shake with recording pill visible on Dashboard → pill is absent from the PNG.
5. Shake twice rapidly (< 1.5s apart) → only one PNG in Photos.
6. Shake on a non-scrolling screen (if any exists) → PNG contains only the visible window (chrome-only fallback).
7. **Release-build verification:** `xcodebuild build -configuration Release` with Release config; `nm AnxietyWatch.app/AnxietyWatch | grep -iE "ShakeResponding|DebugShake|ScreenCapturePipeline|PhotosWriter|_ShakeListener|userDidShake"` returns nothing — confirming no debug-capture symbols ship in the Release binary. Note: `Photos.framework` / `PhotosUI.framework` are still linked because `PrescriptionScannerView` imports `PhotosUI` in Release; the debug capture code contributes no additional framework usage.

### Not unit-tested

- BFS over `UIView` hierarchy. Synthesizing a representative tree per test is brittle and expensive; the decision logic is extracted to `selectScrollView` and tested over candidate tuples instead.
- `PHPhotoLibrary` interaction. System-level API not worth mocking for a debug-only feature.
- Visual rendering output. Eyeballs only.

## Acceptance criteria

This spec is "done" when, on the merged PR:

- [ ] Shake on a real iPhone in a debug build produces a PNG in Photos containing the full screen with chrome.
- [ ] All 15 unit tests pass (`compositeRects` × 5 including the over-window `frameExceedsWindowBounds` regression, `debounceDecision` × 4, `selectScrollView` × 5). Note: both suites happen to have a `noOverflow()` test; they're distinguished by their parent type.
- [ ] Release-build verification (`nm` symbol grep) confirms zero debug-capture code in the shipped binary. Note: `Photos.framework` / `PhotosUI.framework` are still linked from `PrescriptionScannerView`'s pre-existing `import PhotosUI`.
- [ ] `swift-pre-pr-reviewer` agent run on the unpushed diff returns zero "Will Block" findings.
- [ ] iOS CI green (warnings-as-errors, SwiftLint --strict).
- [ ] README has one paragraph describing the feature, the 10,000pt unfurled cap, and how to permission-prompt Photos again if denied.

(The implementation plan lives at `docs/superpowers/plans/2026-05-13-debug-screen-capture.md` locally but is gitignored — it's a working document for the executing session, not a deliverable.)

## Implementation notes (post-merge)

_To be filled in after merge with: PR number, any scope-deltas, lazy-list cases encountered in practice, the `nm` verification output, and any iOS-version-specific quirks discovered._
