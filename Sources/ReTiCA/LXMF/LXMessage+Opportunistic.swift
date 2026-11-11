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

    /// The OLDER reference value of LXMF's `ENCRYPTED_PACKET_MDU` (391 = RNS `Packet.ENCRYPTED_MDU`
    /// + 8, LXMF 1.1.0). Kept only for its existing cross-validation test; `opportunisticFits` does
    /// NOT use it, and LXMF 1.3.0 no longer has this value (see there).
    public static let encryptedPacketMDU = 391

    /// True if this message fits a single opportunistic packet (else DIRECT is required).
    ///
    /// The limit is RNS `Packet.ENCRYPTED_MDU` (383), as in LXMF 1.3.0:
    /// `ENCRYPTED_PACKET_MDU = RNS.Packet.ENCRYPTED_MDU` (LXMessage.py:68). Larger messages go over a
    /// link. A 384...391-byte payload pads to one more AES block and would fit a 500-byte packet only
    /// under HEADER_1; behind a relay it would be refused as too large on every retry.
    public var opportunisticFits: Bool {
        opportunisticPayload.count <= Packet.encryptedMDU
    }

    /// Reconstruct a message received opportunistically: prepend our `lxmf.delivery` destination hash
    /// (which the packet header carried, not the payload) to the decrypted `payload`, then unpack.
    /// `destinationHash` is our delivery-destination hash; `payload` is the decrypted inbound plaintext.
    /// Returns nil for malformed input (LXMF-1 `unpack` rules). Signature validation is separate.
    public static func fromOpportunistic(destinationHash: Data, payload: Data) -> LXMessage? {
        unpack(destinationHash + payload)
    }
}
