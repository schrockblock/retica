import Foundation
import ReTiCA

/// One envelope we sent and the peer has not yet proven: an entry of RNS 1.6.0 `Channel._tx_ring`
/// (Channel.py:519-523) together with the receipt that tracks its packet.
public struct ChannelOutbound: Equatable, Sendable {
    public var sequence: UInt16
    /// The packed envelope. A resend re-encrypts these same bytes (Packet.py:318-330).
    public var raw: Data
    /// The caller's token, echoed in `channelMessageSent` / `channelMessageDelivered`.
    public var token: Data
    /// `Envelope.tries`: 1 after the first send, +1 per resend.
    public var tries: Int
    /// The hash of the packet now carrying the envelope. Only a proof of this hash delivers it: a
    /// resend replaces it, as RNS's receipt follows the re-packed packet.
    public var packetHash: Data
    /// When the packet now carrying the envelope went out (`PacketReceipt.sent_at`).
    public var sentAt: Date
    /// Seconds after `sentAt` at which it times out (`PacketReceipt.timeout`). Only ever grows
    /// while this packet is current (Channel.py:449-453).
    public var timeout: TimeInterval

    public init(sequence: UInt16, raw: Data, token: Data, tries: Int, packetHash: Data,
                sentAt: Date, timeout: TimeInterval) {
        self.sequence = sequence
        self.raw = raw
        self.token = token
        self.tries = tries
        self.packetHash = packetHash
        self.sentAt = sentAt
        self.timeout = timeout
    }
}

/// Why `LinkSession.Action.sendChannelMessage` sent nothing. `nextSequence` is unchanged.
public enum ChannelSendRejection: Equatable, Sendable {
    /// No channel is open on the link.
    case noChannel
    /// The link is not `.active`.
    case linkNotActive
    /// As many envelopes are outstanding as the window allows (Channel.py:413, 504).
    case notReady
    /// The packed envelope exceeds the link MDU (Channel.py:509-510).
    case tooBig
}

/// A `closeStreamWriter` waiting for the channel to be ready, so its EOF can go out.
public struct PendingStreamEOF: Equatable, Sendable {
    public var streamID: UInt16
    public var token: Data

    public init(streamID: UInt16, token: Data) {
        self.streamID = streamID
        self.token = token
    }
}

/// A link's RNS 1.6.0 `Channel`: what `Link.get_channel()` creates (Link.py:1007-1014). Lives in
/// `LinkSession.State.channel`, nil until opened and again after the link closes.
public struct ChannelState: Equatable, Sendable {
    /// Message types this end accepts (`Channel._message_factories` keys). An envelope of any
    /// other type is dropped before the ring (Channel.py:355).
    public var registered: Set<UInt16> = []
    public var rx = ChannelReceiveRing()
    public var window: ChannelSendWindow
    /// `Channel._next_sequence`.
    public var nextSequence: UInt16 = 0
    /// Envelopes sent and not yet proven, in send order. A delivered envelope leaves it, so its
    /// count is the reference's "outstanding".
    public var tx: [ChannelOutbound] = []
    /// Buffer: the stream ids a reader is open for (each `RawChannelReader`'s `_stream_id`). Stream
    /// data for any other id is delivered to nobody, which still advances the ring.
    public var streamReaders: Set<UInt16> = []
    /// Buffer: the stream ids whose writer has closed. Every later write to one carries EOF, as the
    /// reference writer's `_eof` stays set (Buffer.py:259, 279).
    public var closedStreamWriters: Set<UInt16> = []
    /// Buffer: writer closes waiting for the window to free (Buffer.py:276-277), in request order.
    public var pendingStreamEOFs: [PendingStreamEOF] = []

    public init(window: ChannelSendWindow) {
        self.window = window
    }

    /// `Channel.is_ready_to_send` (Channel.py:399-415).
    public var isReadyToSend: Bool { window.isReady(outstanding: tx.count) }

    /// `Channel.mdu` (Channel.py:532-544): the link MDU less the envelope header, capped at 0xFFFF.
    public var mdu: Int { min(Link.mdu - ChannelConstants.envelopeOverhead, 0xFFFF) }
}
