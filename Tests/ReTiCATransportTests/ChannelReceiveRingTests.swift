import Testing
import Foundation
@testable import ReTiCATransport

@Suite("Channel receive ring")
struct ChannelReceiveRingTests {
    private func envelope(_ s: UInt16) -> ChannelEnvelope {
        ChannelEnvelope(msgType: 0x0101, sequence: s, payload: Data([UInt8(s & 0xFF)]))
    }

    @Test func aFreshRingStartsAtZero() {
        let ring = ChannelReceiveRing()
        #expect(ring.nextSequence == 0)
        #expect(ring.pending.isEmpty)
    }

    @Test func deliveredEnvelopesKeepTheirPayload() {
        var ring = ChannelReceiveRing()
        #expect(ring.accept(envelope(1)).isEmpty)
        #expect(ring.accept(envelope(0)) == [envelope(0), envelope(1)])
    }

    /// Review Focus 3: a peer that withholds sequence 0 and floods every in-window sequence cannot grow
    /// the ring past the window (plus one), and nothing is delivered.
    @Test func aFloodOfDistinctInWindowSequencesStaysBounded() {
        var ring = ChannelReceiveRing()
        for _ in 0..<2 {
            for s in UInt16(1)...200 {
                #expect(ring.accept(envelope(s)).isEmpty)
                #expect(ring.pending.count <= ChannelConstants.windowMax + 1)
            }
        }
        #expect(ring.pending.count == ChannelConstants.windowMax)
        #expect(ring.nextSequence == 0)
    }
}
