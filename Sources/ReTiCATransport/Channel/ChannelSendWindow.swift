import Foundation

/// The sender's flow-control window of an RNS 1.6.0 `Channel`: how many envelopes may be outstanding,
/// how far that may grow, and the retry timeout. Pure arithmetic; the caller supplies the link RTT
/// at each step, as the reference reads `self._outlet.rtt` at each step.
public struct ChannelSendWindow: Equatable, Sendable {
    public var window: Int
    public var windowMax: Int
    public var windowMin: Int
    public var windowFlexibility: Int
    public var fastRateRounds: Int
    public var mediumRateRounds: Int

    /// `Channel.__init__` (Channel.py:233-245). A nil RTT counts as 0, which is not slow.
    public init(linkRTT: TimeInterval?) {
        fastRateRounds = 0
        mediumRateRounds = 0
        if (linkRTT ?? 0) > ChannelConstants.rttSlow {
            window = 1
            windowMax = 1
            windowMin = 1
            windowFlexibility = 1
        } else {
            window = ChannelConstants.window
            windowMax = ChannelConstants.windowMaxSlow
            windowMin = ChannelConstants.windowMin
            windowFlexibility = ChannelConstants.windowFlexibility
        }
    }

    /// The window part of `_packet_tx_op` (Channel.py:426-441), run when an envelope is delivered and
    /// leaves the tx ring. A nil or zero RTT skips rate tracking (`if self._outlet.rtt != 0`).
    public mutating func delivered(linkRTT: TimeInterval?) {
        if window < windowMax { window += 1 }

        let rtt = linkRTT ?? 0
        guard rtt != 0 else { return }
        if rtt > ChannelConstants.rttFast {
            fastRateRounds = 0
            if rtt > ChannelConstants.rttMedium {
                mediumRateRounds = 0
            } else {
                mediumRateRounds += 1
                if windowMax < ChannelConstants.windowMaxMedium
                    && mediumRateRounds == ChannelConstants.fastRateThreshold {
                    windowMax = ChannelConstants.windowMaxMedium
                    windowMin = ChannelConstants.windowMinLimitMedium
                }
            }
        } else {
            fastRateRounds += 1
            if windowMax < ChannelConstants.windowMaxFast
                && fastRateRounds == ChannelConstants.fastRateThreshold {
                windowMax = ChannelConstants.windowMaxFast
                windowMin = ChannelConstants.windowMinLimitFast
            }
        }
    }

    /// The shrink branch of `_packet_timeout` (Channel.py:474-477), run when an envelope times out
    /// with retries left.
    public mutating func timedOut() {
        if window > windowMin {
            window -= 1
            if windowMax > windowMin + windowFlexibility {
                windowMax -= 1
            }
        }
    }

    /// `_get_packet_timeout_time` (Channel.py:455-457):
    /// `pow(1.5, tries-1) * max(rtt*2.5, 0.025) * (len(tx_ring)+1.5)`. A nil RTT counts as 0.
    public static func timeout(tries: Int, linkRTT: TimeInterval?, txRingCount: Int) -> TimeInterval {
        let rtt = linkRTT ?? 0
        return pow(1.5, Double(tries - 1)) * max(rtt * 2.5, 0.025) * (Double(txRingCount) + 1.5)
    }

    /// True when another envelope may be sent: `outstanding < window` (Channel.py:413).
    public func isReady(outstanding: Int) -> Bool {
        outstanding < window
    }
}
