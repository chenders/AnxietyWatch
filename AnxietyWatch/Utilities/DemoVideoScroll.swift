#if DEBUG
import SwiftUI

/// Simulator-only video automation. Scrolls each opted-in ScrollView by a
/// deterministic number of programmatic page-sized jumps, then stops. Unlike
/// injected swipes, it cannot rubber-band or continue probing past the bottom.
@MainActor
@Observable
final class DemoVideoSequence {
    static let shared = DemoVideoSequence()
    var completedProfiles: Set<String> = []
    var labsViewed = false
    func markCompleted(_ profile: String) { completedProfiles.insert(profile) }
}

enum DemoVideoScroll {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoAutoScroll")
    }

    static var profile: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-demoScrollProfile"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static var isMainSequence: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoMainSequence")
    }

    static func shouldRun(_ profile: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let isOuraSequence = arguments.contains("-demoOuraSequence")
        let isLabsAndSongsSequence = arguments.contains("-demoLabsAndSongs")
        return (isActive && (self.profile == profile || isMainSequence))
            || (profile == "oura" && isOuraSequence)
            || (profile == "dashboard" && isLabsAndSongsSequence)
    }
}

private struct DemoAutoScrollModifier: ViewModifier {
    let profile: String
    let stops: Int
    let initialDelay: Duration
    let pause: Duration
    let step: CGFloat
    @State private var offset = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($offset)
            .task {
                guard DemoVideoScroll.shouldRun(profile) else { return }
                try? await Task.sleep(for: initialDelay)
                for index in 1...stops {
                    withAnimation(.easeInOut(duration: 1.05)) {
                        offset.scrollTo(y: CGFloat(index) * step)
                    }
                    try? await Task.sleep(for: pause)
                }
                DemoVideoSequence.shared.markCompleted(profile)
            }
    }
}

extension View {
    func demoAutoScroll(
        _ profile: String,
        stops: Int,
        initialDelay: Duration = .seconds(3),
        pause: Duration = .seconds(2),
        step: CGFloat = 510
    ) -> some View {
        modifier(DemoAutoScrollModifier(
            profile: profile, stops: stops, initialDelay: initialDelay,
            pause: pause, step: step
        ))
    }
}
#endif
