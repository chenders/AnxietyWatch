import Foundation

nonisolated enum CNSAlarmChannel: Sendable {
    case watchHaptic
    case standardNotification
    case foregroundAudio
    case inAppBanner
}

nonisolated struct CNSAlarmChannelPolicy {
    nonisolated static func channels(
        tier: CNSAlertTier,
        appActive: Bool
    ) -> Set<CNSAlarmChannel> {
        guard tier == .klaxon else { return [] }

        var channels: Set<CNSAlarmChannel> = [.watchHaptic, .standardNotification]
        if appActive {
            channels.insert(.foregroundAudio)
            channels.insert(.inAppBanner)
        }
        return channels
    }
}
