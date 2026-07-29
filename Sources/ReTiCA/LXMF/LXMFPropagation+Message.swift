import Foundation

/// Propagation pack/open (LXMF-4d-2a): the recipient-encryption boundary for store-and-forward.
/// `pack` encrypts a message's delivery tail (packed[16:]) to the recipient and wraps it in the 4d-1
/// container; `open` reverses it. Encryption is hedged (ephemeral key + IV) — mirrors genuine LXMF
/// LXMessage.pack() PROPAGATED (LXMessage.py:429-436). Core-only (LXMessage, Identity, 4d-1 helpers).
extension LXMFPropagation {
    /// Build the propagation container for `message`, encrypting its delivery tail (packed[16:]) to
    /// `recipientIdentity`. Returns the container bytes and the (single) entry's transient_id. The
    /// encryption is hedged, so the bytes differ per call — callers that retry must reuse the result.
    public static func pack(message: LXMessage, recipientIdentity: Identity, timestamp: Double)
        -> (propagationPacked: Data, transientId: Data) {
        let tail = Data(message.packed.dropFirst(LXMessage.destinationLength))
        let encrypted = recipientIdentity.encrypt(tail)
        let entry = lxmfData(destinationHash: message.destinationHash, encryptedData: encrypted)
        return (container(timestamp: timestamp, entries: [entry]), transientId(lxmfData: entry))
    }

    /// Recover the LXMessage from one container entry by decrypting its tail with `recipientIdentity`.
    /// Returns nil if the entry is malformed or decryption/unpack fails.
    public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage? {
        guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
        let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
        guard let tail = recipientIdentity.decrypt(encrypted) else { return nil }
        return LXMessage.unpack(destHash + tail)
    }
}
