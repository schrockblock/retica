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

    /// Reference LXMF's `ENCRYPTED_PACKET_MDU` (= 391): RNS `Packet.ENCRYPTED_MDU` + 8. Kept for the
    /// cross-validation against reference; `opportunisticFits` does NOT use it (see there).
    public static let encryptedPacketMDU = 391

    /// True if this message fits a single opportunistic packet (else DIRECT is required).
    ///
    /// Deliberate departure from reference LXMF, which falls back opportunistic→direct only above
    /// `ENCRYPTED_PACKET_MDU` (391; LXMessage.py:397-401). A payload of 384...391 bytes pads to one
    /// more AES block and fits a 500-byte packet only under HEADER_1. Toward a destination behind a
    /// relay — or once any relay on the way adds its transport header — it is 515 bytes: Transport
    /// refuses to pack it (`sendFailed(.tooLarge)`), and every retry fails the same way. So the
    /// limit is RNS `Packet.ENCRYPTED_MDU` (383), which fits any header. Larger messages go over a
    /// link, which the recipient accepts as readily.
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
