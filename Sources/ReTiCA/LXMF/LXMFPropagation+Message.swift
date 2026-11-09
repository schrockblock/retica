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
    ///
    /// Returns nil **only** when the enclosing `Task` was cancelled during the stamp search
    /// (`LXStamper.generatePnStamp`), which for a cost of any size is unbounded work. It does not
    /// validate `stampCost`: the ceiling belongs at the boundary where the *wire* value is read
    /// (`LXMFNode.propagationStampCost`), mirroring reference, which decides in
    /// `LXMRouter.get_outbound_propagation_cost` rather than inside `LXStamper`.
    ///
    /// `ratchet` is the recipient's ratchet public key, from `Transport.State.recallRatchet`; the tail
    /// is encrypted to it when given, to the identity key otherwise. Reference encrypts through
    /// `destination.encrypt` (LXMessage.py:437), which takes the recipient's ratchet whenever one is
    /// known (Destination.py:694-708). Pass only a ratchet `recallRatchet` returned: the encryption's key
    /// agreement is force-unwrapped (see `Identity.encrypt`).
    public static func pack(message: LXMessage, recipientIdentity: Identity, ratchet: Data? = nil,
                            timestamp: Double,
                            stampCost: Int = LXMFPropagation.defaultPropagationStampCost) async
        -> (propagationPacked: Data, transientId: Data)? {
        let entry = stamplessEntry(message: message, recipientIdentity: recipientIdentity, ratchet: ratchet,
                                   ephemeralPrivateKey: SecureRandom.bytes(32), iv: SecureRandom.bytes(16))
        let tid = transientId(lxmfData: entry)                                                    // over stampless
        guard let stamp = await LXStamper.generatePnStamp(transientId: tid, targetCost: stampCost)
        else { return nil }
        let stampedEntry = entry + stamp
        return (container(timestamp: timestamp, entries: [stampedEntry]), tid)
    }

    /// The stampless lxmf_data `pack` builds: destination hash ‖ the delivery tail (packed[16:])
    /// encrypted to `ratchet`, or to the identity key when nil. Takes the ephemeral key and IV so a
    /// test can reproduce reference bytes; `pack` passes fresh random ones.
    static func stamplessEntry(message: LXMessage, recipientIdentity: Identity, ratchet: Data?,
                               ephemeralPrivateKey: Data, iv: Data) -> Data {
        let tail = Data(message.packed.dropFirst(LXMessage.destinationLength))
        let encrypted = recipientIdentity.encrypt(tail, ratchet: ratchet,
                                                  ephemeralPrivateKey: ephemeralPrivateKey, iv: iv)
        return lxmfData(destinationHash: message.destinationHash, encryptedData: encrypted)
    }

    /// Recover the packed LXMF wire bytes (destinationHash ‖ decrypted tail) from one container/download
    /// entry, decrypting the tail with `recipientIdentity`. Nil if malformed or decryption fails. The
    /// symmetric inverse of `pack`'s encryption step; `open` is `unpack(recoverPacked(...))`.
    /// Handles both stamped entries (new format: strip trailing 32-byte stamp first) and stampless entries
    /// (old reference fixtures: fall back to decrypting the full tail).
    ///
    /// `ratchets` are the recipient delivery destination's own ratchet private keys, newest first:
    /// each is tried before the identity key, and with `enforceRatchets` the identity key is not tried
    /// — reference decrypts a propagated message through `delivery_destination.decrypt`
    /// (Destination.py:720-752).
    public static func recoverPacked(lxmfData: Data, recipientIdentity: Identity, ratchets: [Data]? = nil,
                                     enforceRatchets: Bool = false) -> Data? {
        guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
        let raw = Data(lxmfData.dropFirst(LXMessage.destinationLength))
        // Try stripping the trailing stamp first (stamped entries, new format).
        if raw.count > LXStamper.stampSize {
            let stripped = Data(strippedCore(lxmfData: lxmfData).dropFirst(LXMessage.destinationLength))
            if let tail = recipientIdentity.decrypt(stripped, ratchets: ratchets, enforceRatchets: enforceRatchets) {
                return destHash + tail
            }
        }
        // Fall back to decrypting the full tail (stampless entries, old fixtures).
        guard let tail = recipientIdentity.decrypt(raw, ratchets: ratchets, enforceRatchets: enforceRatchets)
        else { return nil }
        return destHash + tail
    }

    /// Recover the LXMessage from one container entry by decrypting its tail with `recipientIdentity`
    /// (and `ratchets` first, see `recoverPacked`). Returns nil if the entry is malformed or
    /// decryption/unpack fails.
    public static func open(lxmfData: Data, recipientIdentity: Identity, ratchets: [Data]? = nil,
                            enforceRatchets: Bool = false) -> LXMessage? {
        guard let packed = recoverPacked(lxmfData: lxmfData, recipientIdentity: recipientIdentity,
                                         ratchets: ratchets, enforceRatchets: enforceRatchets)
        else { return nil }
        return LXMessage.unpack(packed)
    }
}
