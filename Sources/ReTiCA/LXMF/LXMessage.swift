import Foundation

/// A Lightweight Extensible Message Format (LXMF) message — the RNS application message envelope.
/// Pure value type, byte-compatible with reference lxmf 1.1.0 (LXMessage.py). LXMF-1 scope: the
/// message core with an empty `fields` map (plain title+content messages); rich integer-keyed
/// fields and stamps are deferred to later slices.
public struct LXMessage: Equatable {
    public static let destinationLength = 16      // RNS TRUNCATED_HASHLENGTH/8
    public static let signatureLength = 64        // RNS SIGLENGTH/8

    public let destinationHash: Data              // 16
    public let sourceHash: Data                   // 16
    public let timestamp: Double
    public let title: Data                        // utf-8 bytes (may be empty)
    public let content: Data                      // utf-8 bytes (may be empty)
    public let hash: Data                         // 32 — message ID
    public let signature: Data                    // 64

    /// LXMF app name and delivery aspect. A message's source/destination hashes are the hashes of the
    /// parties' `<identity>.lxmf.delivery` destinations — NOT raw identity hashes. A receiver recalls
    /// the source identity from `sourceHash` (RNS Identity.recall of the delivery-destination hash)
    /// to validate the signature (LXMessage.py:776-809).
    public static let appName = "lxmf"
    public static let deliveryAspects = ["delivery"]

    /// The `lxmf.delivery` destination hash for an identity — what LXMF stores as source/destination hash.
    public static func deliveryHash(identityHash: Data) -> Data {
        Destination.hash(identityHash: identityHash, appName: appName, aspects: deliveryAspects)
    }

    /// The msgpack of the 4-element payload [timestamp, title, content, {}] — the exact bytes the
    /// reference packs (empty fields map as the 4th element).
    private static func payloadBytes(timestamp: Double, title: Data, content: Data) -> Data {
        MsgPack.encode(.array([.double(timestamp), .bin(title), .bin(content), .map([])]))
    }

    /// Build and sign a message from the source identity. `sourceHash` is derived as the source's
    /// `lxmf.delivery` destination hash; `destinationHash` is the recipient's `lxmf.delivery`
    /// destination hash. `title`/`content` are raw utf-8 bytes.
    public static func create(source: Identity, destinationHash: Data,
                              timestamp: Double, title: Data, content: Data) -> LXMessage {
        let sourceHash = deliveryHash(identityHash: source.hash)
        let payload = payloadBytes(timestamp: timestamp, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        let signature = source.sign(hashedPart + hash)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature)
    }

    /// The on-wire bytes: destinationHash ‖ sourceHash ‖ signature ‖ msgpack(payload).
    public var packed: Data {
        destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content)
    }

    /// Parse wire bytes back into a message (structure + recomputed hash). Returns nil for malformed
    /// input or a payload that is not exactly [float64, bin, bin, empty-map] (this rejects rich
    /// integer-keyed `fields`, which LXMF-1 does not yet support). Signature validation is separate.
    public static func unpack(_ data: Data) -> LXMessage? {
        let headerLen = 2 * destinationLength + signatureLength
        guard data.count >= headerLen else { return nil }
        let destinationHash = Data(data.prefix(destinationLength))
        let sourceHash = Data(data.dropFirst(destinationLength).prefix(destinationLength))
        let signature = Data(data.dropFirst(2 * destinationLength).prefix(signatureLength))
        let packedPayload = Data(data.dropFirst(headerLen))
        guard let value = MsgPack.decodeValue(packedPayload),
              case let .array(items) = value, items.count == 4,
              case let .double(timestamp) = items[0],
              case let .bin(title) = items[1],
              case let .bin(content) = items[2],
              case let .map(pairs) = items[3], pairs.isEmpty
        else { return nil }
        // Hash is recomputed from the received payload bytes (== msgpack(payload) for LXMF-1). The
        // reference re-packs payload[:4] when stripping a stamp (5th element); we reject stamped/rich
        // messages above, so packedPayload is always the exact hashed bytes here (LXMF-5 will revisit).
        let hash = Crypto.fullHash(destinationHash + sourceHash + packedPayload)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature)
    }

    /// Recompute the hashed/signed parts from this message's fields and validate the signature
    /// against the resolved source identity (the caller resolves it by `sourceHash`).
    public func validateSignature(source: Identity) -> Bool {
        let payload = LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        return source.validate(signature: signature, message: hashedPart + hash)
    }
}
