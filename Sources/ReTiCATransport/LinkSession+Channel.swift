import Foundation
import ComposableArchitecture
import ReTiCA

/// The RNS 1.6.0 `Channel` driven from `LinkSession`'s reducer. The reducer cases stay thin and
/// call these. The pure parts are `ChannelEnvelope`, `ChannelReceiveRing` and `ChannelSendWindow`;
/// this file holds what needs the session: the packet, the proof, the timers.
extension LinkSession {
    /// What the retry timer of one outbound envelope led to.
    enum ChannelDeadlineOutcome {
        /// The envelope is gone (delivered) or the channel is closed: nothing to do.
        case ignored
        /// Resent under a new packet hash, timer re-armed.
        case resent(Effect<Action>)
        /// Out of tries: the caller tears the link down (Channel.py:469, 479-483).
        case exhausted
    }

    /// `Link.get_channel()` (Link.py:1007-1014): idempotent. A closed link stays without one, so
    /// "channel is nil once the link has closed" holds whatever arrives late.
    func openChannel(_ state: inout State) {
        guard state.channel == nil, state.status != .closed else { return }
        state.channel = ChannelState(window: ChannelSendWindow(linkRTT: state.rtt))
    }

    /// Drop the channel and cancel every retry timer it armed (`Channel._shutdown`, Channel.py:303-320,
    /// called from `link_closed`, Link.py:775). Eager cancels: call it only on a close path.
    func closeChannel(_ state: inout State) -> Effect<Action> {
        guard let channel = state.channel else { return .none }
        state.channel = nil
        return .merge(channel.tx.map { Effect<Action>.cancel(id: CancelID.channel($0.sequence)) })
    }

    /// A CHANNEL-context link packet on an active link (Link.py:1234-1242). Without an open channel it
    /// is dropped: no proof, no decrypt. With one it is proven FIRST, then decrypted, then handed to
    /// the channel, so a packet that fails to decrypt or parse, or carries an unregistered type, is
    /// still proven.
    func receiveChannelPacket(_ state: inout State, _ packet: Packet,
                              decrypt: (Data, Data) -> Data?) -> Effect<Action> {
        guard state.channel != nil else { return .none }                       // Link.py:1235-1236
        let proof = proofTransmit(state, packetHash: packet.packetHash)        // Link.py:1238
        guard let plain = decrypt(packet.payload, state.sessionKey),           // Link.py:1239-1240
              let envelope = ChannelEnvelope.parse(plain),                      // Channel.py:353
              state.channel?.registered.contains(envelope.msgType) == true     // Channel.py:355 raises
        else { return proof }
        let ready = state.channel?.rx.accept(envelope) ?? []                   // Channel.py:357-394
        return .concatenate([proof] + ready.map {
            .send(.delegate(.channelMessageReceived(msgType: $0.msgType, payload: $0.payload)))
        })
    }

    /// `Channel.send` (Channel.py:495-530). The sequence is taken only once the send is certain to go
    /// out, which is the reference's reserve-then-roll-back with nothing in between to observe.
    func sendChannelMessage(_ state: inout State, type: ChannelMessageType, payload: Data,
                            token: Data) -> Effect<Action> {
        func reject(_ reason: ChannelSendRejection) -> Effect<Action> {
            .send(.delegate(.channelSendRejected(token: token, reason: reason)))
        }
        guard var channel = state.channel else { return reject(.noChannel) }
        guard state.status == .active else { return reject(.linkNotActive) }
        guard channel.isReadyToSend else { return reject(.notReady) }          // Channel.py:504
        let sequence = channel.nextSequence
        let raw = ChannelEnvelope(msgType: type.rawValue, sequence: sequence, payload: payload).packed()
        guard raw.count <= Link.mdu else { return reject(.tooBig) }            // Channel.py:509-510
        // Unreachable with an envelope inside the MDU; the reference answers an outlet that did not
        // transmit with ME_LINK_NOT_READY and rolls the sequence back (Channel.py:515-517).
        guard let (packetHash, wire) = channelPacket(state, raw) else { return reject(.linkNotActive) }
        let now = date.now
        channel.nextSequence = sequence &+ 1                                    // Channel.py:511, % SEQ_MODULUS
        // Emplace, then compute the timeout with the envelope counted (Channel.py:519-523).
        channel.tx.append(ChannelOutbound(sequence: sequence, raw: raw, token: token, tries: 1,
                                          packetHash: packetHash, sentAt: now, timeout: 0))
        let timeout = ChannelSendWindow.timeout(tries: 1, linkRTT: state.rtt, txRingCount: channel.tx.count)
        channel.tx[channel.tx.count - 1].timeout = timeout
        let extend = extendChannelTimeouts(&channel, linkRTT: state.rtt, now: now)  // Channel.py:524
        state.channel = channel
        return .merge(
            .concatenate(.send(.delegate(.transmit(state.interfaceID, wire))),
                         .send(.delegate(.channelMessageSent(token: token, sequence: sequence)))),
            channelTimer(sequence, after: timeout),
            extend)
    }

    /// A link proof that matched no `sendWithReceipt` receipt: does it deliver a channel envelope?
    /// Only the CURRENT packet hash of an outbound counts, since a resend moved the receipt to the new
    /// packet (Packet.py:318-330), and the signature must verify under the peer's key. Delivery is
    /// `_packet_delivered` → `_packet_tx_op` (Channel.py:417-447).
    func channelProofReceived(_ state: inout State, proofHash: Data, signature: Data) -> Effect<Action> {
        guard var channel = state.channel,
              let index = channel.tx.firstIndex(where: { $0.packetHash == proofHash }),
              let peer = proofValidator(state),
              peer.validate(signature: signature, message: proofHash)
        else { return .none }
        let outbound = channel.tx.remove(at: index)
        channel.window.delivered(linkRTT: state.rtt)
        state.channel = channel
        return .merge(.cancel(id: CancelID.channel(outbound.sequence)),
                      .send(.delegate(.channelMessageDelivered(token: outbound.token))))
    }

    /// `_packet_timeout` (Channel.py:459-493). A resend re-encrypts the same envelope bytes into a
    /// fresh packet, so new ciphertext and a new hash (Packet.py:318-330), and its timeout is computed
    /// with the envelope still in the ring (Channel.py:485-490).
    func channelDeadline(_ state: inout State, sequence: UInt16) -> ChannelDeadlineOutcome {
        guard state.status == .active, var channel = state.channel,
              let index = channel.tx.firstIndex(where: { $0.sequence == sequence })
        else { return .ignored }                                               // Channel.py:467
        if channel.tx[index].tries >= ChannelConstants.maxTries { return .exhausted }  // Channel.py:469
        channel.tx[index].tries += 1                                           // Channel.py:471
        channel.window.timedOut()                                              // Channel.py:474-477
        let now = date.now
        var effects: [Effect<Action>] = []
        if let (packetHash, wire) = channelPacket(state, channel.tx[index].raw) {
            channel.tx[index].packetHash = packetHash
            effects.append(.send(.delegate(.transmit(state.interfaceID, wire))))
        }
        channel.tx[index].sentAt = now
        let timeout = ChannelSendWindow.timeout(tries: channel.tx[index].tries, linkRTT: state.rtt,
                                                txRingCount: channel.tx.count)
        channel.tx[index].timeout = timeout
        effects.append(channelTimer(sequence, after: timeout))                 // Channel.py:489
        effects.append(extendChannelTimeouts(&channel, linkRTT: state.rtt, now: now))  // Channel.py:490
        state.channel = channel
        return .resent(.merge(effects))
    }

    /// `_update_packet_timeouts` (Channel.py:449-453): recompute each outstanding envelope's timeout
    /// for the ring as it now is, and adopt it only if it is longer. Timeouts never shrink.
    func extendChannelTimeouts(_ channel: inout ChannelState, linkRTT: TimeInterval?, now: Date) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        for index in channel.tx.indices {
            let outbound = channel.tx[index]
            let updated = ChannelSendWindow.timeout(tries: outbound.tries, linkRTT: linkRTT,
                                                    txRingCount: channel.tx.count)
            guard updated > outbound.timeout else { continue }
            channel.tx[index].timeout = updated
            effects.append(channelTimer(outbound.sequence,
                                        after: outbound.sentAt.addingTimeInterval(updated).timeIntervalSince(now)))
        }
        return .merge(effects)
    }

    /// The link DATA packet carrying an envelope under context CHANNEL, built as `.sendWithReceipt`
    /// builds its packet; nil if it cannot be packed.
    func channelPacket(_ state: State, _ envelope: Data) -> (packetHash: Data, wire: Data)? {
        let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .channel, contextFlag: false, hops: 0,
                            destinationHash: state.linkID, transportId: nil,
                            payload: Link.encrypt(envelope, sessionKey: state.sessionKey))
        guard let wire = try? packet.packed() else { return nil }
        return (packet.packetHash, wire)
    }

    /// (Re-)arm the retry timer of envelope `sequence` to fire `delay` seconds from now.
    func channelTimer(_ sequence: UInt16, after delay: TimeInterval) -> Effect<Action> {
        let clock = self.clock
        let delay = max(0, delay)
        return .run { send in
            try await clock.sleep(for: .seconds(delay))
            await send(.channelDeadline(sequence: sequence))
        }
        .cancellable(id: CancelID.channel(sequence), cancelInFlight: true)
    }
}
