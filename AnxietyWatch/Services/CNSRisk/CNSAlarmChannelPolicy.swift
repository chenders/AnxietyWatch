import Foundation

nonisolated enum CNSAlarmChannel: Sendable {
    case watchHaptic
    case criticalNotification
    case timeSensitiveNotification
    case foregroundAudio
    case inAppBanner
}

nonisolated struct CNSAlarmChannelPolicy {
    nonisolated static func channels(
        tier: CNSAlertTier,
        criticalGranted: Bool,
        timeSensitiveGranted: Bool,
        appActive: Bool
    ) -> Set<CNSAlarmChannel> {
        guard tier == .klaxon else { return [] }

        var channels: Set<CNSAlarmChannel> = [.watchHaptic]
        if criticalGranted {
            channels.insert(.criticalNotification)
        } else if timeSensitiveGranted {
            channels.insert(.timeSensitiveNotification)
        }
        if appActive {
            channels.insert(.foregroundAudio)
            channels.insert(.inAppBanner)
        }
        return channels
    }
}
