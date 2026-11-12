import Foundation

/// The Channel receive ring: a line-by-line transcription of RNS 1.6.0 `Channel._emplace_envelope`
/// (Channel.py:322-341) and the window check and contiguous sweep of `Channel._receive`
/// (Channel.py:357-394). Arithmetic is done in `Int` widened from `UInt16`, so it has Python's integer
/// semantics: no operand is negative where `%` is used, and `next + WINDOW_MAX` in the upper check is
/// deliberately NOT wrapped (Channel.py:367).
///
/// The caller unpacks first and drops unregistered message types before calling `accept`
/// (Channel.py:355 unpacks before the window check). The ring does not know about types.
///
/// Bounded on remote input: `accept` only stores sequences in the window `[next, next + WINDOW_MAX]`
/// (wrapping into `[0, (next + WINDOW_MAX) % SEQ_MODULUS]` near the top), duplicates are refused, and
/// `next` never advances past a stored sequence. So the ring holds at most `windowMax + 1` envelopes.
///
/// Reference behaviour kept as is: near the wrap, `_emplace_envelope` appends small wrapped sequences
/// instead of inserting them in order (Channel.py:331's `(next - seq) > SEQ_MAX//2` clause), and the
/// sweep is a single pass in ring order. A ring like `[2, 1, 0, 0xFFFE, 0xFFFF]` therefore delivers
/// 0xFFFE, 0xFFFF, 0 and leaves 1 and 2 waiting for the next `accept` to sweep again.
public struct ChannelReceiveRing: Equatable, Sendable {
    /// `Channel._next_rx_sequence`.
    public private(set) var nextSequence: UInt16
    /// `Channel._rx_ring`, in the reference ring order (which is not always sequence order).
    private(set) var pending: [ChannelEnvelope]

    public init() {
        self.init(nextSequence: 0)                                          // Channel.py:230
    }

    init(nextSequence: UInt16) {
        self.nextSequence = nextSequence
        self.pending = []                                                   // Channel.py:227
    }

    /// The envelopes now deliverable, in order. Empty for an out-of-window, duplicate or
    /// gap-leaving envelope.
    public mutating func accept(_ envelope: ChannelEnvelope) -> [ChannelEnvelope] {
        let next = Int(truncatingIfNeeded: nextSequence)
        let sequence = Int(truncatingIfNeeded: envelope.sequence)
        if sequence < next {                                                // Channel.py:357
            let windowOverflow = (next + ChannelConstants.windowMax) % ChannelConstants.seqModulus // :358
            if windowOverflow < next {                                      // Channel.py:359
                if sequence > windowOverflow {                              // Channel.py:360
                    return []                                               // Channel.py:361-362
                }
            } else {                                                        // Channel.py:363
                return []                                                   // Channel.py:364-365
            }
        } else if sequence > next + ChannelConstants.windowMax {            // Channel.py:367 (unwrapped)
            return []                                                       // Channel.py:368-369
        }

        guard emplace(envelope) else {                                      // Channel.py:371
            return []                                                       // Channel.py:373-375
        }

        var contiguous: [ChannelEnvelope] = []                              // Channel.py:378
        for e in pending {                                                  // Channel.py:379
            if e.sequence == nextSequence {                                 // Channel.py:380
                contiguous.append(e)                                        // Channel.py:381
                advance()                                                   // Channel.py:382
                if nextSequence == 0 {                                      // Channel.py:383
                    for e in pending {                                      // Channel.py:384
                        if e.sequence == nextSequence {                     // Channel.py:385
                            contiguous.append(e)                            // Channel.py:386
                            advance()                                       // Channel.py:387
                        }
                    }
                }
            }
        }

        // Channel.py:389-394. The reference removes by identity; sequences in the ring are unique
        // (emplace refuses duplicates), so removing the first envelope with that sequence is the same.
        for e in contiguous {                                               // Channel.py:389
            if let index = pending.firstIndex(where: { $0.sequence == e.sequence }) {
                pending.remove(at: index)                                   // Channel.py:393
            }
        }
        return contiguous                                                   // Channel.py:394 (callbacks)
    }

    /// `(self._next_rx_sequence + 1) % Channel.SEQ_MODULUS` (Channel.py:382, 387).
    private mutating func advance() {
        let next = Int(truncatingIfNeeded: nextSequence)
        nextSequence = UInt16(truncatingIfNeeded: (next + 1) % ChannelConstants.seqModulus)
    }

    /// `Channel._emplace_envelope` (Channel.py:322-341). False for a duplicate.
    private mutating func emplace(_ envelope: ChannelEnvelope) -> Bool {
        let next = Int(truncatingIfNeeded: nextSequence)
        let sequence = Int(truncatingIfNeeded: envelope.sequence)
        for (i, existing) in pending.enumerated() {                         // Channel.py:324-326, 336
            let existingSequence = Int(truncatingIfNeeded: existing.sequence)
            if sequence == existingSequence {                               // Channel.py:327
                return false                                                // Channel.py:329
            }
            if sequence < existingSequence
                && !((next - sequence) > ChannelConstants.seqMax / 2) {     // Channel.py:331
                pending.insert(envelope, at: i)                             // Channel.py:332
                return true                                                 // Channel.py:334
            }
        }
        pending.append(envelope)                                            // Channel.py:339
        return true                                                         // Channel.py:341
    }
}
