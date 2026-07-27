import Foundation

extension LXMessage {
    /// The plaintext for an opportunistic send: `packed` minus the leading 16-byte destinationHash
    /// (the RNS packet header carries the destination). Hand this to Transport's `.send` toward the
    /// recipient's `lxmf.delivery` destination — `LXMessage.deliveryHash(recipientIdentityHash)` —
    /// which encrypts it to the recipient's identity. Mirrors reference LXMF's opportunistic packet:
    /// `RNS.Packet(delivery_destination, packed[DESTINATION_LENGTH:])` (LXMessage.py:634).
    public var opportunisticPayload: Data {
        Data(packed.dropFirst(LXMessage.destinationLength))
    }

    /// Reconstruct a message received opportunistically: prepend our `lxmf.delivery` destination hash
    /// (which the packet header carried, not the payload) to the decrypted `payload`, then unpack.
    /// `destinationHash` is our delivery-destination hash; `payload` is the decrypted inbound plaintext.
    /// Returns nil for malformed input (LXMF-1 `unpack` rules). Signature validation is separate.
    public static func fromOpportunistic(destinationHash: Data, payload: Data) -> LXMessage? {
        unpack(destinationHash + payload)
    }
}
