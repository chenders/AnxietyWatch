import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the recording-display formatter that renders elapsed-time
/// strings for the in-app pill and the live view. The Live Activity uses
/// SwiftUI's `Text(timerInterval:)` for tick-free system rendering so it
/// does not exercise this helper.
@Suite("RecordingFormatters.formatElapsed")
struct RecordingFormattersTests {

    @Test("formats zero as 0:00")
    func zero() {
        #expect(RecordingFormatters.formatElapsed(0) == "0:00")
    }

    @Test("formats sub-minute as 0:SS")
    func subMinute() {
        #expect(RecordingFormatters.formatElapsed(7) == "0:07")
        #expect(RecordingFormatters.formatElapsed(59) == "0:59")
    }

    @Test("formats minute boundary as M:00")
    func minuteBoundary() {
        #expect(RecordingFormatters.formatElapsed(60) == "1:00")
    }

    @Test("formats sub-hour as M:SS")
    func subHour() {
        #expect(RecordingFormatters.formatElapsed(75) == "1:15")
        #expect(RecordingFormatters.formatElapsed(3_599) == "59:59")
    }

    @Test("formats hour boundary as H:MM:SS")
    func hourBoundary() {
        #expect(RecordingFormatters.formatElapsed(3_600) == "1:00:00")
    }

    @Test("formats multi-hour as H:MM:SS")
    func multiHour() {
        // 5h 3m 12s
        #expect(RecordingFormatters.formatElapsed(18_192) == "5:03:12")
    }

    @Test("truncates fractional seconds toward zero")
    func truncatesFraction() {
        #expect(RecordingFormatters.formatElapsed(59.9) == "0:59")
        #expect(RecordingFormatters.formatElapsed(60.5) == "1:00")
    }

    @Test("treats negative input as zero (defensive)")
    func negativeIsZero() {
        #expect(RecordingFormatters.formatElapsed(-1) == "0:00")
        #expect(RecordingFormatters.formatElapsed(-3_600) == "0:00")
    }
}
