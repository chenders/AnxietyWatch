#if DEBUG
import Foundation
import CoreGraphics
import SwiftUI
import UIKit
import Photos
import os

extension Notification.Name {
    /// Posted on `UIEvent.EventSubtype.motionShake`. Consumed by
    /// `_ShakeListener`. DEBUG builds only.
    static let userDidShake = Notification.Name("app.anxietywatch.debug.userDidShake")
}

/// Tiny UIViewController that becomes first responder on appear and
/// posts `.userDidShake` when the device is shaken. Visually empty.
///
/// `motionEnded` only fires on the current first responder (then
/// propagates up the chain), so anything else that claims FR steals
/// shakes from us. The notable claimants in this app:
///   - Focused text fields (`UITextField` / `UITextView`)
///   - **iOS 18's new `Tab { ... }` API**: each tab is wrapped in its
///     own `UIHostingController`, and switching tabs hands FR to the
///     new tab's hosting controller, leaving our sibling-of-TabView
///     responder un-claimed until the next reclaim event fires.
///
/// We reclaim FR on:
///   - `viewDidAppear` (initial claim)
///   - `keyboardDidHide` (text field resigned)
///   - `didBecomeActive` (app foregrounded)
///   - A 1.5s timer (catches tab switches and any other claim loss)
///
/// The timer guards against stealing FR from active text input by
/// checking `isKeyboardVisible` first. Shaking *while* the keyboard is
/// up still misses; documented in README as "tap outside text fields
/// first."
private final class _ShakeRespondingViewController: UIViewController {
    private var isKeyboardVisible = false
    private var reclaimTimer: Timer?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(reclaimFirstResponder(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(reclaimFirstResponder(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        // Tab-switch / unknown-FR-claim catchall. 1.5s is long enough
        // that this isn't a battery concern even in long debug
        // sessions; short enough that the user doesn't notice a delay
        // after switching tabs before shake works.
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isFirstResponder && !self.isKeyboardVisible {
                self.becomeFirstResponder()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    deinit {
        reclaimTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reclaimFirstResponder(_ notification: Notification) {
        if !isFirstResponder && !isKeyboardVisible {
            becomeFirstResponder()
        }
    }

    @objc private func keyboardWillShow(_ notification: Notification) { isKeyboardVisible = true }
    @objc private func keyboardWillHide(_ notification: Notification) { isKeyboardVisible = false }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .userDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

/// SwiftUI bridge for the shake responder. Mount in a `background` /
/// `overlay` modifier — it has no visible content.
struct ShakeResponderRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        _ShakeRespondingViewController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// DEBUG-build-only screen-capture pipeline. Shake the device → full-length
/// PNG of the current screen lands in Photos. See
/// `docs/superpowers/specs/2026-05-13-debug-screen-capture-design.md`.
///
/// This entire file is wrapped in `#if DEBUG`, so release builds contain
/// none of this file's symbols or capture code (verified by `nm` on the
/// Release binary). Note: AnxietyWatch already links `Photos.framework`
/// / `PhotosUI.framework` in Release because `PrescriptionScannerView`
/// imports `PhotosUI` — this DEBUG file contributes no additional
/// Release framework usage.
enum ScreenCapturePipeline {

    /// Layout for stitching a chrome image (window snapshot with the
    /// scroll region clipped) and an unfurled scroll-content image into
    /// a single tall canvas.
    struct CompositeLayout: Equatable {
        let canvasSize: CGSize
        let topChromeRect: CGRect
        let topChromeSourceRect: CGRect
        let unfurledRect: CGRect
        let bottomChromeRect: CGRect
        let bottomChromeSourceRect: CGRect
    }

    /// Pure math: given the chrome image size, the scrollview's frame in
    /// window coordinates, and the unfurled content size, compute where
    /// each piece lands in the final canvas.
    ///
    /// Returns a chrome-only layout when there is no overflow to unfurl
    /// (`heightDelta <= 0`). In that case the caller should blit only
    /// `topChromeRect` (which equals the full canvas); `unfurledRect`,
    /// `bottomChromeRect`, and `bottomChromeSourceRect` are all `.zero`.
    static func compositeRects(
        chromeSize: CGSize,
        scrollFrameInWindow: CGRect,
        unfurledSize: CGSize
    ) -> CompositeLayout {
        // Clamp the scrollview frame into the chrome bounds so the source
        // rects can't have negative widths/heights if the live frame
        // briefly extends past the window (mid-rotation, mid-sheet-dismiss).
        let clampedMinY = max(0, scrollFrameInWindow.minY)
        let clampedMaxY = min(chromeSize.height, scrollFrameInWindow.maxY)
        let clampedFrame = CGRect(
            x: scrollFrameInWindow.minX,
            y: clampedMinY,
            width: scrollFrameInWindow.width,
            height: max(0, clampedMaxY - clampedMinY)
        )

        // heightDelta must be computed from the CLAMPED viewport height so
        // the canvas accommodates the full unfurled content. If we used the
        // unclamped height, an over-window scroll frame would undersize the
        // canvas and silently clip the bottom of the unfurled image.
        let heightDelta = unfurledSize.height - clampedFrame.height

        if heightDelta <= 0 {
            return CompositeLayout(
                canvasSize: chromeSize,
                topChromeRect: CGRect(origin: .zero, size: chromeSize),
                topChromeSourceRect: CGRect(origin: .zero, size: chromeSize),
                unfurledRect: .zero,
                bottomChromeRect: .zero,
                bottomChromeSourceRect: .zero
            )
        }

        let canvasSize = CGSize(width: chromeSize.width, height: chromeSize.height + heightDelta)

        let topChromeSourceRect = CGRect(
            x: 0, y: 0,
            width: chromeSize.width,
            height: clampedFrame.minY
        )
        let topChromeRect = topChromeSourceRect

        let unfurledRect = CGRect(
            x: clampedFrame.minX,
            y: clampedFrame.minY,
            width: clampedFrame.width,
            height: unfurledSize.height
        )

        let bottomChromeSourceRect = CGRect(
            x: 0,
            y: clampedFrame.maxY,
            width: chromeSize.width,
            height: chromeSize.height - clampedFrame.maxY
        )
        let bottomChromeRect = CGRect(
            x: 0,
            y: clampedFrame.maxY + heightDelta,
            width: bottomChromeSourceRect.width,
            height: bottomChromeSourceRect.height
        )

        return CompositeLayout(
            canvasSize: canvasSize,
            topChromeRect: topChromeRect,
            topChromeSourceRect: topChromeSourceRect,
            unfurledRect: unfurledRect,
            bottomChromeRect: bottomChromeRect,
            bottomChromeSourceRect: bottomChromeSourceRect
        )
    }

    /// Returns `true` when a shake at `now` should trigger a capture,
    /// given the time of the previous capture (`lastFire`) and the
    /// debounce window in seconds. Boundary is inclusive (== window
    /// fires). A `window` of 0 always fires.
    static func debounceDecision(now: Date, lastFire: Date?, window: TimeInterval) -> Bool {
        guard let lastFire else { return true }
        return now.timeIntervalSince(lastFire) >= window
    }

    /// Snapshot of a candidate UIScrollView found during BFS, captured
    /// as plain data so the selection logic can be tested without a
    /// live view hierarchy.
    struct ScrollCandidate: Equatable {
        let id: Int
        let depth: Int
        let frameInWindow: CGRect
        let contentSize: CGSize
        /// `scroll.adjustedContentInset`. Captured so the overflow
        /// check accounts for the actually-visible area (between nav
        /// bar / tab bar overlays), not the raw bounds.
        let adjustedContentInset: UIEdgeInsets
        let isInsidePillOverlay: Bool

        /// The actually-visible content area: bounds.height minus
        /// inset overlays (nav bar above + tab bar below).
        var visibleHeight: CGFloat {
            frameInWindow.height - adjustedContentInset.top - adjustedContentInset.bottom
        }
    }

    /// Picks the deepest scrollview whose content overflows its
    /// **actually-visible** area (`contentSize.height > visibleHeight`,
    /// where visibleHeight subtracts adjustedContentInset top + bottom)
    /// and is not inside the recording-pill overlay. Returns nil if no
    /// candidate qualifies.
    ///
    /// Comparing against `visibleHeight` rather than raw `frameInWindow
    /// .height` is the difference between "overflows the chrome
    /// rectangle" and "overflows what the user can actually see" — the
    /// latter is what makes scroll-and-stitch worthwhile. A Form under
    /// a large nav bar (insets.top ≈ 95pt) plus a tab bar
    /// (insets.bottom ≈ 83pt) can have content shorter than bounds.height
    /// but still overflow the visible region; the previous predicate
    /// false-negatived this case and fell back to chrome-only.
    ///
    /// Filters out degenerate candidates (`visibleHeight <= 0`) first.
    /// Without that filter, a zero-height transition-state scrollview
    /// (e.g., one being torn down mid-dismiss) would trivially pass
    /// the overflow check (any positive contentSize > 0) and could
    /// out-rank a real overflowing scrollview at lower depth, forcing
    /// a chrome-only fallback even when a usable target exists.
    static func selectScrollView(candidates: [ScrollCandidate]) -> ScrollCandidate? {
        candidates
            .filter { !$0.isInsidePillOverlay }
            .filter { $0.visibleHeight > 0 }
            .filter { $0.contentSize.height > $0.visibleHeight }
            .max(by: { $0.depth < $1.depth })
    }

    /// Walks the presented-VC chain from the keyWindow's root, then BFS
    /// the topmost VC's view to collect candidate scrollviews. The pill
    /// view is identified by its `accessibilityIdentifier`; any
    /// scrollview that is a descendant of the pill view is flagged so
    /// `selectScrollView` can skip it.
    @MainActor
    static func findTopmostScrollView(in window: UIWindow) -> UIScrollView? {
        guard var topVC = window.rootViewController else { return nil }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        let pillView = findPillView(in: topVC.view)

        var candidates: [ScrollCandidate] = []
        var liveScrollViews: [Int: UIScrollView] = [:]
        var queue: [(UIView, Int)] = [(topVC.view, 0)]
        var nextID = 0

        while !queue.isEmpty {
            let (view, depth) = queue.removeFirst()
            if let scroll = view as? UIScrollView,
               !scroll.isHidden,
               scroll.alpha > 0.01 {
                let frameInWindow = scroll.convert(scroll.bounds, to: window)
                let isInsidePill = pillView.map { scroll.isDescendant(of: $0) } ?? false
                let id = nextID
                nextID += 1
                candidates.append(
                    ScrollCandidate(
                        id: id,
                        depth: depth,
                        frameInWindow: frameInWindow,
                        contentSize: scroll.contentSize,
                        adjustedContentInset: scroll.adjustedContentInset,
                        isInsidePillOverlay: isInsidePill
                    )
                )
                liveScrollViews[id] = scroll
            }
            for subview in view.subviews {
                queue.append((subview, depth + 1))
            }
        }

        guard let selected = selectScrollView(candidates: candidates) else { return nil }
        return liveScrollViews[selected.id]
    }

    /// BFS for the first UIView whose accessibilityIdentifier matches
    /// `RecordingStatusPill.debugAccessibilityIdentifier`.
    @MainActor
    static func findPillView(in root: UIView) -> UIView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if v.accessibilityIdentifier == RecordingStatusPill.debugAccessibilityIdentifier {
                return v
            }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }

    /// Renders the key window at its current bounds. Caller is
    /// responsible for hiding the pill view before calling and
    /// restoring it after.
    @MainActor
    static func renderChromeImage(window: UIWindow) -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Maximum unfurled content height (in points) before
    /// `renderUnfurledScrollContent` short-circuits to `nil`. A
    /// 10,000pt-tall content at 3x scale is roughly a 142 MB bitmap —
    /// well below realistic OOM but above any normal app scrollview
    /// (Dashboard chart stack is ~2,500pt). Anything taller is almost
    /// certainly pathological; the caller falls back to chrome-only.
    static let maxUnfurledHeight: CGFloat = 10_000

    /// Captures the full scrollable content by scrolling through the
    /// scrollview in viewport-sized steps and stitching each snapshot
    /// together.
    ///
    /// We deliberately do NOT resize the scrollview's `bounds.size`
    /// directly. SwiftUI's `HostingScrollView` is layered on top of
    /// `UIScrollView` and its hosted content is sized by SwiftUI's
    /// geometry resolver, not by UIKit bounds. Mutating bounds while
    /// the SwiftUI hierarchy is live produces an inconsistent layer
    /// state and the Core Animation render server rejects the draw
    /// ("Render server returned error for view … SwiftUI.HostingScrollView"),
    /// which surfaced as empty/black unfurled regions in real-device
    /// testing. Scrolling + snapshotting at natural viewport size
    /// works because it's the same path the system uses for the
    /// built-in Side+VolUp screenshot.
    ///
    /// Bonus: this scroll-through pattern materializes lazy `List` /
    /// `LazyVStack` rows as they enter the viewport, so the stitched
    /// image captures rows that weren't already rendered at trigger
    /// time. This obsoletes the lazy-rows limitation noted in the spec.
    ///
    /// Returns `nil` when content height is zero or exceeds
    /// `maxUnfurledHeight` (rendering such a bitmap risks OOM).
    /// `defer` restores the original `contentOffset` on any exit
    /// path.
    ///
    /// Strategy: scroll programmatically + snapshot the WINDOW + crop
    /// to the scroll's visible content region. We do NOT call
    /// `scroll.drawHierarchy` directly. Real-device testing showed
    /// that drawHierarchy on a SwiftUI `HostingScrollView` returns
    /// failure intermittently during programmatic scroll (matching
    /// the "Render server returned error for view … SwiftUI.HostingScrollView"
    /// log), producing essentially-blank snapshots that show up as
    /// black bands in the final image. `window.drawHierarchy` doesn't
    /// have this issue — it's the same path the system uses for the
    /// native Side+VolUp screenshot, and we already rely on it for
    /// the chrome image.
    ///
    /// Steps by `visibleHeight = bounds.height - insets.top - insets.bottom`
    /// — the scroll's actually-visible content area (between nav bar
    /// and tab bar) — so each cropped snapshot fills its canvas slot
    /// exactly. The async sleep between offset change and snapshot
    /// gives SwiftUI's lazy content (`LazyVStack`, `Form`, `List`)
    /// time to materialize freshly-visible rows for the new offset.
    @MainActor
    static func renderUnfurledScrollContent(
        _ scroll: UIScrollView,
        in window: UIWindow
    ) async -> UIImage? {
        let contentSize = scroll.contentSize
        let viewportSize = scroll.bounds.size
        let insets = scroll.adjustedContentInset
        let visibleHeight = viewportSize.height - insets.top - insets.bottom

        guard contentSize.height > 0,
              contentSize.height <= maxUnfurledHeight,
              visibleHeight > 0 else {
            return nil
        }

        let scrollFrameInWindow = scroll.convert(scroll.bounds, to: window)
        // Window-coords rect of the scroll's actually-visible content
        // (excluding the inset regions where chrome overlays).
        let visibleInWindow = CGRect(
            x: scrollFrameInWindow.minX,
            y: scrollFrameInWindow.minY + insets.top,
            width: scrollFrameInWindow.width,
            height: visibleHeight
        )

        let originalOffset = scroll.contentOffset
        defer {
            scroll.contentOffset = originalOffset
            scroll.layoutIfNeeded()
        }

        // Scrollable range: contentOffset.y in [-insets.top, contentSize.height
        // - visibleHeight - insets.top]. At natural top (-insets.top) the
        // visible content shows rows [0, visibleHeight]; at max offset, rows
        // [contentSize - visibleHeight, contentSize].
        let minOffsetY: CGFloat = -insets.top
        let maxOffsetY = max(minOffsetY, contentSize.height - visibleHeight - insets.top)

        // Build the final canvas as a CGBitmapContext and draw each
        // cropped slice into it during the capture loop. This avoids
        // accumulating all slices in memory and then compositing in a
        // second pass — peak memory becomes (canvas) + (1 in-flight
        // slice) + (1 in-flight window snapshot) instead of (canvas) +
        // (Σ slices). For a 10,000pt cap that's roughly a 50 MB
        // reduction (~140 MB peak vs. ~290 MB).
        let scale = window.screen.scale
        let canvasSize = CGSize(width: scrollFrameInWindow.width, height: contentSize.height)
        let pixelWidth = Int((canvasSize.width * scale).rounded())
        let pixelHeight = Int((canvasSize.height * scale).rounded())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Flip Y so we can use UIKit-style top-down point coordinates.
        // After this CTM, drawing at (0, 0) lands at the top-left of
        // the bitmap, +Y goes down, and 1 unit = 1 point.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        var canvasY: CGFloat = 0
        while canvasY < contentSize.height {
            // Increment canvasY first so any `continue` exit (guard
            // failure) still makes progress and can't infinite-loop.
            let stepCanvasY = canvasY
            canvasY += visibleHeight

            let desiredOffsetY = minOffsetY + stepCanvasY
            let actualOffsetY = min(desiredOffsetY, maxOffsetY)
            scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: actualOffsetY)
            scroll.layoutIfNeeded()

            // ~3 frames at 60fps. Long enough for SwiftUI's lazy
            // rendering (LazyVStack/Form/List) to materialize the
            // freshly-visible rows; short enough not to be perceptible
            // during the capture pause.
            try? await Task.sleep(nanoseconds: 50_000_000)

            let windowRenderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let windowSnapshot = windowRenderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }

            // Crop the window snapshot to the scroll's visible content
            // region. `cropping(to:)` operates in CGImage pixel coords,
            // hence `.scaled(by: scale).integral`. Intersect with the
            // CGImage's pixel bounds so a transient over-window frame
            // (mid-rotation / mid-sheet-transition) doesn't push the
            // rect past the image edge — that would make
            // `cropping(to:)` return nil and silently drop a slice,
            // leaving a missing band in the stitched image.
            guard let cgImage = windowSnapshot.cgImage else { continue }
            let cgImageBounds = CGRect(
                x: 0, y: 0,
                width: cgImage.width,
                height: cgImage.height
            )
            let scaledCrop = visibleInWindow
                .scaled(by: windowSnapshot.scale)
                .integral
                .intersection(cgImageBounds)
            guard !scaledCrop.isEmpty,
                  let cropped = cgImage.cropping(to: scaledCrop) else { continue }
            let croppedImage = UIImage(
                cgImage: cropped,
                scale: windowSnapshot.scale,
                orientation: windowSnapshot.imageOrientation
            )

            // Map scroll offset → canvas y. The snapshot's visible
            // content rows are [actualOffsetY + insets.top,
            // actualOffsetY + insets.top + visibleHeight]; canvas
            // y for content row R = R. So canvas y for the snapshot's
            // top = actualOffsetY + insets.top.
            let drawY = actualOffsetY + insets.top
            croppedImage.draw(in: CGRect(
                x: 0, y: drawY,
                width: croppedImage.size.width,
                height: croppedImage.size.height
            ))
            // `croppedImage` and `windowSnapshot` fall out of scope at
            // loop iteration end — released by ARC before the next
            // step allocates new ones.
        }

        guard let cgFinal = context.makeImage() else { return nil }
        return UIImage(cgImage: cgFinal, scale: scale, orientation: .up)
    }

    /// Composites a chrome image and (optionally) an unfurled scroll
    /// content image into a single tall image. Uses `compositeRects` to
    /// compute the layout; this function just draws.
    @MainActor
    static func composite(
        chrome: UIImage,
        unfurled: UIImage?,
        scrollFrameInWindow: CGRect
    ) -> UIImage {
        guard let unfurled else { return chrome }

        let layout = compositeRects(
            chromeSize: chrome.size,
            scrollFrameInWindow: scrollFrameInWindow,
            unfurledSize: unfurled.size
        )

        if layout.canvasSize == chrome.size {
            return chrome
        }

        let renderer = UIGraphicsImageRenderer(size: layout.canvasSize)
        return renderer.image { ctx in
            // Background fill. The chrome draw below covers canvas
            // y in [0, chrome.height], and the shifted bottom chrome
            // covers the tail — but the EXTENDED middle region
            // [chrome.height, unfurledRect.maxY] is only covered by
            // the unfurled image, and only across the scrollview's
            // width. For narrower-than-window scrollviews, that
            // leaves transparent left/right gutters in the extension.
            // Filling with systemBackground first guarantees no
            // transparent pixels make it into the final PNG.
            UIColor.systemBackground.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: layout.canvasSize))

            // Background: draw the full chrome image anchored at canvas
            // top. This covers the region above the scrollview AND any
            // left/right gutters in the chrome-height span when the
            // scrollview is narrower than the window — the unfurled
            // overlay below covers the chrome's scroll-region middle.
            chrome.draw(in: CGRect(origin: .zero, size: chrome.size))

            unfurled.draw(in: layout.unfurledRect)

            // Bottom chrome: crop the below-scroll region of the chrome
            // image and draw at the shifted position. `.integral` snaps
            // to whole pixels because `CGImage.cropping` is sensitive to
            // fractional rects (can return nil or surprise-resize).
            if layout.bottomChromeRect.height > 0 {
                let bottomSourceRect = layout.bottomChromeSourceRect
                    .scaled(by: chrome.scale)
                    .integral
                if let bottomCropCG = chrome.cgImage?.cropping(to: bottomSourceRect) {
                    let bottomImage = UIImage(
                        cgImage: bottomCropCG,
                        scale: chrome.scale,
                        orientation: chrome.imageOrientation
                    )
                    bottomImage.draw(in: layout.bottomChromeRect)
                }
            }
        }
    }
}

private extension CGRect {
    /// Scales the rect by a uniform factor — used to translate
    /// UIKit-points crop coordinates into the CGImage's pixel
    /// coordinates (CGImage cropping operates in pixels, not points).
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: origin.x * factor, y: origin.y * factor,
               width: size.width * factor, height: size.height * factor)
    }
}

enum PhotosWriter {
    /// Writes the image to Photos as PNG.
    ///
    /// The naive path — `PHAssetCreationRequest.creationRequestForAsset(from:)`
    /// — lets Photos pick its own encoding (HEIC on modern devices, JPEG
    /// on older ones), which is lossy and defeats the point of a debug
    /// capture used for pixel-accurate review. So we encode PNG bytes
    /// ourselves, stage them in a temp file, and ask Photos to import
    /// the file with `shouldMoveFile = true` so it consumes the staging
    /// path on success.
    ///
    /// PNG encoding and the synchronous file write happen inside a
    /// `Task.detached` so they don't stall the main actor — a long
    /// Dashboard PNG can be 5–15 MB and `UIImage.pngData()` plus the
    /// disk write together take a few hundred ms on a modern device.
    /// The caller is on `@MainActor`; only the Photos request block
    /// and the haptic come back to main after the await.
    ///
    /// Propagates whatever `PHPhotoLibrary` raises (typically `NSError`);
    /// the caller catches generically and haptic-signals success/failure.
    static func save(_ image: UIImage) async throws {
        let tempURL = try await Task.detached(priority: .userInitiated) {
            guard let pngData = image.pngData() else {
                throw NSError(domain: "PhotosWriter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "UIImage.pngData() returned nil"
                ])
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AnxietyWatchDebugCapture-\(UUID().uuidString).png")
            try pngData.write(to: url, options: .atomic)
            return url
        }.value
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: tempURL, options: options)
        }
    }
}

/// Public modifier — mount on ContentView. Owns NO @State; all state
/// lives inside `_ShakeListener` so observation is scoped to a 0×0
/// invisible view, not the whole tab tree. See CLAUDE.md "@Observable
/// reads at App / WindowGroup scope" for the cascade rationale.
struct DebugShakeCapture: ViewModifier {
    func body(content: Content) -> some View {
        content.background(_ShakeListener())
    }
}

/// Owns the shake responder bridge, the debounce state, and the
/// capture pipeline invocation. Re-renders here do not propagate to
/// the host (it's a 0×0 sibling, not a wrapper).
private struct _ShakeListener: View {
    @State private var lastFireTime: Date?
    /// Prevents overlapping capture pipelines. The 1.5s debounce only
    /// gates on shake-time, but `runCapture` is async and can outlast
    /// the debounce window (typical: 700ms; long: ~1.5s+). Without an
    /// in-flight guard, two captures can interleave and corrupt the
    /// pill-hide / `contentOffset` restoration state.
    @State private var captureInProgress = false

    private static let debounceWindow: TimeInterval = 1.5

    var body: some View {
        ShakeResponderRepresentable()
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(for: .userDidShake)) { _ in
                handleShake()
            }
    }

    @MainActor
    private func handleShake() {
        guard !captureInProgress else {
            Log.debugScreenCapture.info("Capture already in flight; skipping this shake")
            return
        }
        let now = Date()
        guard ScreenCapturePipeline.debounceDecision(
            now: now,
            lastFire: lastFireTime,
            window: Self.debounceWindow
        ) else { return }
        lastFireTime = now
        captureInProgress = true

        Task { @MainActor in
            defer { captureInProgress = false }
            await runCapture()
        }
    }

    @MainActor
    private func runCapture() async {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow else {
            Log.debugScreenCapture.error("No key window found; skipping capture")
            return
        }

        let pillView = ScreenCapturePipeline.findPillView(in: window)
        let pillWasHidden = pillView?.isHidden ?? false
        pillView?.isHidden = true
        defer { pillView?.isHidden = pillWasHidden }

        window.layoutIfNeeded()
        let chrome = ScreenCapturePipeline.renderChromeImage(window: window)

        let scrollView = ScreenCapturePipeline.findTopmostScrollView(in: window)
        let final: UIImage
        if let scrollView {
            let frameInWindow = scrollView.convert(scrollView.bounds, to: window)
            let insets = scrollView.adjustedContentInset
            // Visible content frame in window coords: the rectangle on
            // chrome where actual scroll content shows (excluding the
            // inset overlay regions where nav bar / tab bar sit).
            // `composite` uses this as the placement target for the
            // unfurled image, which is now content-height only (no
            // inset rows).
            let visibleContentFrame = CGRect(
                x: frameInWindow.minX,
                y: frameInWindow.minY + insets.top,
                width: frameInWindow.width,
                height: max(0, frameInWindow.height - insets.top - insets.bottom)
            )
            let unfurled = await ScreenCapturePipeline.renderUnfurledScrollContent(
                scrollView,
                in: window
            )
            if unfurled == nil {
                Log.debugScreenCapture.warning("""
                Unfurled render returned nil (contentSize \
                \(Int(scrollView.contentSize.width))×\(Int(scrollView.contentSize.height))pt, \
                cap \(Int(ScreenCapturePipeline.maxUnfurledHeight))pt); chrome-only fallback
                """)
            }
            final = ScreenCapturePipeline.composite(
                chrome: chrome,
                unfurled: unfurled,
                scrollFrameInWindow: visibleContentFrame
            )
        } else {
            final = chrome
        }

        do {
            try await PhotosWriter.save(final)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Log.debugScreenCapture.info("Saved capture: \(Int(final.size.width))×\(Int(final.size.height))")
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            Log.debugScreenCapture.error("Capture save failed: \(String(describing: error))")
        }
    }
}
#endif
