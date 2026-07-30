import Foundation

/// A Lightweight Extensible Message Format (LXMF) message — the RNS application message envelope.
/// Pure value type, byte-compatible with reference lxmf 1.1.0 (LXMessage.py). Carries the message core
/// plus optional rich integer-keyed `fields` (LXMF-5a) and an optional proof-of-work `stamp` (LXMF-5b,
/// the payload's 5th element).
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
    public let fields: [MsgPackValue.IntPair]     // ordered integer-keyed fields (empty = none)
    public let stamp: Data?                       // optional PoW delivery stamp (payload 5th element)

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

    private static func payloadBytes(timestamp: Double, title: Data, content: Data,
                                     fields: [MsgPackValue.IntPair], stamp: Data? = nil) -> Data {
        let fieldsValue: MsgPackValue = fields.isEmpty ? .map([]) : .intMap(fields)
        var items: [MsgPackValue] = [.double(timestamp), .bin(title), .bin(content), fieldsValue]
        if let stamp { items.append(.bin(stamp)) }
        return MsgPack.encode(.array(items))
    }

    /// Build and sign a message from the source identity. `sourceHash` is derived as the source's
    /// `lxmf.delivery` destination hash; `destinationHash` is the recipient's `lxmf.delivery`
    /// destination hash. `title`/`content` are raw utf-8 bytes.
    public static func create(source: Identity, destinationHash: Data,
                              timestamp: Double, title: Data, content: Data,
                              fields: [MsgPackValue.IntPair] = []) -> LXMessage {
        let sourceHash = deliveryHash(identityHash: source.hash)
        let payload = payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        let signature = source.sign(hashedPart + hash)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature, fields: fields, stamp: nil)
    }

    /// The on-wire bytes: destinationHash ‖ sourceHash ‖ signature ‖ msgpack(payload).
    public var packed: Data {
        destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content,
                                     fields: fields, stamp: stamp)
    }

    /// A copy of this message with a delivery stamp attached (hash/signature unchanged — the stamp is
    /// not part of the signed payload). The stamp is produced by `LXStamper.generateStamp(messageId: hash, …)`.
    public func withStamp(_ stamp: Data) -> LXMessage {
        LXMessage(destinationHash: destinationHash, sourceHash: sourceHash, timestamp: timestamp,
                  title: title, content: content, hash: hash, signature: signature, fields: fields, stamp: stamp)
    }

    /// Validate the attached stamp against `targetCost` (workblock derived from this message's hash).
    public func validateStamp(targetCost: Int) -> Bool {
        guard let stamp else { return false }
        return LXStamper.stampValid(stamp: stamp, targetCost: targetCost,
                                    workblock: LXStamper.stampWorkblock(material: hash))
    }

    /// Parse wire bytes back into a message (structure + recomputed hash). The payload is a 4-element
    /// array [float64, bin, bin, fields] — where `fields` is an empty map or an integer-keyed map — with
    /// an optional 5th `bin` stamp element. The hash is recomputed over the 4-element payload (the stamp
    /// is excluded, matching the reference). Returns nil for malformed input. Signature validation is separate.
    public static func unpack(_ data: Data) -> LXMessage? {
        let headerLen = 2 * destinationLength + signatureLength
        guard data.count >= headerLen else { return nil }
        let destinationHash = Data(data.prefix(destinationLength))
        let sourceHash = Data(data.dropFirst(destinationLength).prefix(destinationLength))
        let signature = Data(data.dropFirst(2 * destinationLength).prefix(signatureLength))
        let packedPayload = Data(data.dropFirst(headerLen))
        guard let value = MsgPack.decodeValue(packedPayload),
              case let .array(items) = value, items.count == 4 || items.count == 5,
              case let .double(timestamp) = items[0],
              case let .bin(title) = items[1],
              case let .bin(content) = items[2]
        else { return nil }
        let fields: [MsgPackValue.IntPair]
        switch items[3] {
        case let .map(pairs) where pairs.isEmpty: fields = []
        case let .intMap(pairs): fields = pairs
        default: return nil
        }
        let stamp: Data?
        if items.count == 5 {
            guard case let .bin(s) = items[4] else { return nil }
            stamp = s
        } else { stamp = nil }
        // Hash is over the 4-element payload only (stamp excluded); re-pack payload[:4] when a stamp is present.
        let hashPayload = items.count == 5
            ? payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
            : packedPayload
        let hash = Crypto.fullHash(destinationHash + sourceHash + hashPayload)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature, fields: fields, stamp: stamp)
    }

    /// Recompute the hashed/signed parts from this message's fields and validate the signature
    /// against the resolved source identity (the caller resolves it by `sourceHash`).
    public func validateSignature(source: Identity) -> Bool {
        let payload = LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        return source.validate(signature: signature, message: hashedPart + hash)
    }
}
