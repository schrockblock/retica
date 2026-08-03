import Foundation

/// Propagation pack/open (LXMF-4d-2a): the recipient-encryption boundary for store-and-forward.
/// `pack` encrypts a message's delivery tail (packed[16:]) to the recipient and wraps it in the 4d-1
/// container; `open` reverses it. Encryption is hedged (ephemeral key + IV) — mirrors genuine LXMF
/// LXMessage.pack() PROPAGATED (LXMessage.py:429-436). Core-only (LXMessage, Identity, 4d-1 helpers).
extension LXMFPropagation {
    /// Build the propagation container for `message`, encrypting its delivery tail (packed[16:]) to
    /// `recipientIdentity` and appending a propagation stamp. Returns the container bytes (with the stamped
    /// entry) and the (single) entry's transient_id (computed over the stampless entry — the stable dedup
    /// key). The encryption is hedged, so the bytes differ per call — callers that retry must reuse the result.
    public static func pack(message: LXMessage, recipientIdentity: Identity, timestamp: Double,
                            stampCost: Int = LXMFPropagation.defaultPropagationStampCost)
        -> (propagationPacked: Data, transientId: Data) {
        let tail = Data(message.packed.dropFirst(LXMessage.destinationLength))
        let encrypted = recipientIdentity.encrypt(tail)
        let entry = lxmfData(destinationHash: message.destinationHash, encryptedData: encrypted)  // stampless
        let tid = transientId(lxmfData: entry)                                                    // over stampless
        let stamp = LXStamper.generatePnStamp(transientId: tid, targetCost: stampCost)
        let stampedEntry = entry + stamp
        return (container(timestamp: timestamp, entries: [stampedEntry]), tid)
    }

    /// Recover the packed LXMF wire bytes (destinationHash ‖ decrypted tail) from one container/download
    /// entry, decrypting the tail with `recipientIdentity`. Nil if malformed or decryption fails. The
    /// symmetric inverse of `pack`'s encryption step; `open` is `unpack(recoverPacked(...))`.
    /// Handles both stamped entries (new format: strip trailing 32-byte stamp first) and stampless entries
    /// (old reference fixtures: fall back to decrypting the full tail).
    public static func recoverPacked(lxmfData: Data, recipientIdentity: Identity) -> Data? {
        guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
        let raw = Data(lxmfData.dropFirst(LXMessage.destinationLength))
        // Try stripping the trailing stamp first (stamped entries, new format).
        if raw.count > LXStamper.stampSize {
            let stripped = Data(strippedCore(lxmfData: lxmfData).dropFirst(LXMessage.destinationLength))
            if let tail = recipientIdentity.decrypt(stripped) {
                return destHash + tail
            }
        }
        // Fall back to decrypting the full tail (stampless entries, old fixtures).
        guard let tail = recipientIdentity.decrypt(raw) else { return nil }
        return destHash + tail
    }

    /// Recover the LXMessage from one container entry by decrypting its tail with `recipientIdentity`.
    /// Returns nil if the entry is malformed or decryption/unpack fails.
    public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage? {
        guard let packed = recoverPacked(lxmfData: lxmfData, recipientIdentity: recipientIdentity) else { return nil }
        return LXMessage.unpack(packed)
    }
}
