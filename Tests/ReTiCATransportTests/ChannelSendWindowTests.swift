import Testing
import Foundation
@testable import ReTiCATransport

@Suite("Channel send window")
struct ChannelSendWindowTests {
    @Test func readinessCountsOutstandingAgainstWindow() {
        var window = ChannelSendWindow(linkRTT: 0.5)
        #expect(window.window == 2)
        #expect(window.isReady(outstanding: 0))
        #expect(window.isReady(outstanding: 1))
        #expect(!window.isReady(outstanding: 2))
        #expect(!window.isReady(outstanding: 3))

        window.delivered(linkRTT: 0.5)
        #expect(window.window == 3)
        #expect(window.isReady(outstanding: 2))
        #expect(!window.isReady(outstanding: 3))

        let slow = ChannelSendWindow(linkRTT: 2.0)
        #expect(slow.isReady(outstanding: 0))
        #expect(!slow.isReady(outstanding: 1))
    }

    @Test func aNilRTTCountsAsZero() {
        let unknown = ChannelSendWindow(linkRTT: nil)
        #expect(unknown == ChannelSendWindow(linkRTT: 0))
        #expect(unknown.window == ChannelConstants.window)
        #expect(unknown.windowMax == ChannelConstants.windowMaxSlow)

        var tracked = unknown
        for _ in 0..<12 { tracked.delivered(linkRTT: nil) }
        #expect(tracked.fastRateRounds == 0)
        #expect(tracked.mediumRateRounds == 0)
        #expect(tracked.window == ChannelConstants.windowMaxSlow)
        #expect(tracked.windowMax == ChannelConstants.windowMaxSlow)

        #expect(ChannelSendWindow.timeout(tries: 1, linkRTT: nil, txRingCount: 0)
            == ChannelSendWindow.timeout(tries: 1, linkRTT: 0, txRingCount: 0))
    }
}
