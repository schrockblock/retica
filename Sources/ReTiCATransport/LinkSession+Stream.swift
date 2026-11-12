import Foundation
import ComposableArchitecture

/// RNS 1.6.0 `Buffer` (Buffer.py) on this link's channel: stream data is the system message type
/// `0xFF00`, carried by the channel's own send path, retries and proofs (`LinkSession+Channel.swift`).
/// The session does not buffer stream bytes: each delivered chunk is a `streamDataReceived`, and
/// consumers own the buffering `RawChannelReader` does.
extension LinkSession {
    /// `RawChannelReader.__init__` (Buffer.py:123-129): register `0xFF00` on the channel (opening it
    /// if needed) and start delivering `streamID`. Nothing on a closed link, which has no channel.
    /// An id above 0x3FFF could never match, since unpack masks inbound ids to 14 bits (Buffer.py:92):
    /// the reference accepts it and stays silent forever; this refuses it and registers nothing.
    func openStreamReader(_ state: inout State, streamID: UInt16) -> Effect<Action> {
        guard streamID <= StreamDataHeader.streamIDMax else {
            return .send(.delegate(.streamIDRejected(streamID: streamID, token: nil)))
        }
        openChannel(&state)
        state.channel?.registered.insert(ChannelMessageType.streamData.rawValue)
        state.channel?.streamReaders.insert(streamID)
        return .none
    }

    /// A received `0xFF00` envelope as `StreamDataMessage.unpack` leaves it (Buffer.py:88-98): nil
    /// where unpack raises (shorter than the header, or bz2 that is bad or does not end within 16
    /// KiB), otherwise the envelope with its data inflated and the compressed bit cleared, so it is
    /// inflated once and the ring holds what the reference's holds.
    static func inflatedStreamEnvelope(_ envelope: ChannelEnvelope) -> ChannelEnvelope? {
        guard let (header, data) = StreamDataHeader.parse(envelope.payload),
              let bytes = StreamChunker.decodeStreamPayload(header, data) else { return nil }
        var inflated = envelope
        inflated.payload = StreamDataHeader(streamID: header.streamID, eof: header.eof, compressed: false).packed() + bytes
        return inflated
    }

    /// `RawChannelWriter.write` (Buffer.py:232-267): one chunk, answered by `streamWritten`.
    func writeStream(_ state: inout State, streamID: UInt16, data: Data, token: Data) -> Effect<Action> {
        let parts = writeStreamParts(&state, streamID: streamID, data: data, token: token)
        return .merge(parts.ordered, parts.timers)
    }

    /// `writeStream`'s effects in two parts: `ordered` (the transmit, then `streamWritten`), quick
    /// sends that a caller may concatenate with others; and `timers`, the long-running retry timers,
    /// which must be MERGED, never concatenated before anything, or what follows waits for them.
    func writeStreamParts(_ state: inout State, streamID: UInt16, data: Data,
                          token: Data) -> (ordered: Effect<Action>, timers: Effect<Action>) {
        // An id above 14 bits: the reference's StreamDataMessage raises ValueError (Buffer.py:74-75)
        // where pack would otherwise mask it onto another stream. It raises whatever the channel's
        // state, so this is checked first, and answered distinctly: `streamWritten(0)` means retry.
        guard streamID <= StreamDataHeader.streamIDMax else {
            return (ordered: .send(.delegate(.streamIDRejected(streamID: streamID, token: token))), timers: .none)
        }
        let nothing = (ordered: Effect<Action>.send(.delegate(.streamWritten(token: token, consumed: 0))),
                       timers: Effect<Action>.none)
        // Not ready, inactive or no channel: the ME_LINK_NOT_READY path, 0 (Buffer.py:264-267).
        // Checked before chunking only to spare the bz2 work; `enqueueChannelEnvelope` refuses the same.
        guard let channel = state.channel, state.status == .active, channel.isReadyToSend else { return nothing }
        let chunk = StreamChunker.chunk(data, writerMDU: channel.mdu - StreamDataHeader.length)   // Buffer.py:230
        let header = StreamDataHeader(streamID: streamID, eof: channel.closedStreamWriters.contains(streamID),
                                      compressed: chunk.compressed)                             // Buffer.py:259
        switch enqueueChannelEnvelope(&state, msgType: ChannelMessageType.streamData.rawValue,
                                      payload: header.packed() + chunk.payload, token: token) {
        case .failure:
            return nothing   // .tooBig cannot happen: the chunk respects the writer MDU
        case let .success(sent):
            return (ordered: .concatenate(sent.transmit,
                                          .send(.delegate(.streamWritten(token: token, consumed: chunk.consumed)))),
                    timers: sent.timers)
        }
    }

    /// `RawChannelWriter.close` (Buffer.py:269-280): wait while the channel is not ready, up to
    /// `streamEOFWait`, then mark the writer EOF and write once with no data. That write is reported
    /// `streamWritten(token, consumed: 0)` whether it went out or not: like the reference, whose
    /// `write` returns 0 on ME_LINK_NOT_READY and whose `close` ignores the result, a failed EOF is
    /// lost silently. A wait is ended early by the delivery that makes the channel ready
    /// (`flushStreamEOFsIfReady`), and abandoned with no delegate if the link closes first.
    ///
    /// An id above 0x3FFF is refused at once with nothing marked: the reference would wait out the
    /// same delay and then raise ValueError from the EOF write (Buffer.py:74-75, 279-280).
    func closeStreamWriter(_ state: inout State, streamID: UInt16, token: Data) -> Effect<Action> {
        guard streamID <= StreamDataHeader.streamIDMax else {
            return .send(.delegate(.streamIDRejected(streamID: streamID, token: token)))
        }
        guard let channel = state.channel else {
            return .send(.delegate(.streamWritten(token: token, consumed: 0)))
        }
        guard !channel.isReadyToSend else { return sendStreamEOF(&state, streamID: streamID, token: token).merged }
        state.channel?.pendingStreamEOFs.append(PendingStreamEOF(streamID: streamID, token: token))
        let wait = Self.streamEOFWait(linkRTT: state.rtt, txRingCount: channel.tx.count)
        let clock = self.clock
        return .run { send in
            try await clock.sleep(for: .seconds(wait))
            await send(.streamEOFDeadline(streamID: streamID, token: token))
        }
        .cancellable(id: CancelID.streamEOF(streamID: streamID, token: token), cancelInFlight: true)
    }

    /// How long `close` waits for the channel to become ready: `link.rtt * len(tx_ring)` seconds, or
    /// 15 when that raises because the RTT is unknown (Buffer.py:270-274).
    static func streamEOFWait(linkRTT: TimeInterval?, txRingCount: Int) -> TimeInterval {
        guard let linkRTT else { return 15 }
        return max(linkRTT * Double(txRingCount), 0)
    }

    /// A pending EOF's wait ran out: try it once, ready or not (Buffer.py:276-280).
    func streamEOFDeadline(_ state: inout State, streamID: UInt16, token: Data) -> Effect<Action> {
        guard let index = state.channel?.pendingStreamEOFs.firstIndex(of: PendingStreamEOF(streamID: streamID, token: token))
        else { return .none }
        state.channel?.pendingStreamEOFs.remove(at: index)
        return sendStreamEOF(&state, streamID: streamID, token: token).merged
    }

    /// Run on every delivery: while the channel is ready, the oldest waiting close sends its EOF and
    /// stops waiting. A close that finds the window full again keeps waiting, with its own deadline
    /// still armed, for a later delivery: each reference `close` polls `is_ready_to_send` on its own
    /// (Buffer.py:276-277), so one freed slot releases one EOF, and the rest stay blocked. Eager
    /// cancels: each cancels only the wait it ends. The EOFs' transmits and `streamWritten`s go out in
    /// order; their retry timers are merged alongside, so no EOF waits on an earlier one's timer.
    func flushStreamEOFsIfReady(_ state: inout State) -> Effect<Action> {
        var ordered: [Effect<Action>] = []
        var timers: [Effect<Action>] = []
        while let channel = state.channel, channel.isReadyToSend, let pending = channel.pendingStreamEOFs.first {
            state.channel?.pendingStreamEOFs.removeFirst()
            timers.append(.cancel(id: CancelID.streamEOF(streamID: pending.streamID, token: pending.token)))
            let parts = sendStreamEOF(&state, streamID: pending.streamID, token: pending.token)
            ordered.append(parts.ordered)
            timers.append(parts.timers)
        }
        return .merge(.concatenate(ordered), .merge(timers))
    }

    /// `self._eof = True; self.write(bytes())` (Buffer.py:279-280). An empty write consumes 0, so its
    /// `streamWritten` reads 0 whether or not it was sent.
    private func sendStreamEOF(_ state: inout State, streamID: UInt16,
                               token: Data) -> (ordered: Effect<Action>, timers: Effect<Action>, merged: Effect<Action>) {
        state.channel?.closedStreamWriters.insert(streamID)
        let parts = writeStreamParts(&state, streamID: streamID, data: Data(), token: token)
        return (parts.ordered, parts.timers, .merge(parts.ordered, parts.timers))
    }
}
