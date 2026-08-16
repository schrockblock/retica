import Foundation

/// A Lightweight Extensible Message Format (LXMF) message — the RNS application message envelope.
/// Pure value type, byte-compatible with reference lxmf 1.1.0 (LXMessage.py). Carries the message core
/// plus optional rich integer-keyed `fields` (LXMF-5a) and an optional proof-of-work `stamp` (LXMF-5b,
/// the payload's 5th element).
public struct LXMessage: Equatable, Sendable {
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

    /// The exact bytes `unpack` was given, retained so signature validation and forwarding use what
    /// the sender actually sent rather than what our encoder would have produced. `nil` for messages
    /// built locally by `create`, which have no wire form yet.
    ///
    /// Mirrors reference `message.packed = lxmf_bytes` (lxmf 1.1.0 `LXMessage.py:798`). Without it a
    /// sender whose MessagePack encoder differs from ours in any single legal way — a `bin16` length
    /// prefix where we emit `bin8`, say — fails signature validation and the message is dropped.
    /// Excluded from `==` on purpose: see the `Equatable` conformance below.
    public let receivedBytes: Data?

    /// Whether the delivery stamp was found valid. **Meaningless unless `stampChecked` is true** —
    /// read the two together (see `stampChecked` for the tri-state).
    ///
    /// Mirrors reference `self.stamp_valid = False` (lxmf 1.1.0 `LXMessage.py:157`), set by
    /// `LXMRouter.lxmf_delivery` at `LXMRouter.py:1865/1868`. **Not a wire field** — it is a local
    /// validation result, never encoded by `packed` and never parsed by `unpack`, exactly as in
    /// reference where the pair lives on the object and never enters `pack()`.
    public let stampValid: Bool

    /// Whether stamp validation was actually attempted. False when no `deliveryStampCost` is
    /// configured, so nothing was checked.
    ///
    /// Mirrors reference `self.stamp_checked = False` (lxmf 1.1.0 `LXMessage.py:158`), set to True on
    /// **both** branches of `LXMRouter.py:1865-1869`. Together with `stampValid` this preserves the
    /// three states reference exists to distinguish, which a single boolean cannot:
    ///
    /// | `stampChecked` | `stampValid` | meaning                                       |
    /// |----------------|--------------|-----------------------------------------------|
    /// | `false`        | `false`      | **never checked** — no cost configured        |
    /// | `true`         | `true`       | checked, stamp valid                          |
    /// | `true`         | `false`      | checked, stamp invalid or absent              |
    ///
    /// Collapsing the last two into one boolean would report an unchecked message as having failed.
    public let stampChecked: Bool

    /// Compares message content only. `receivedBytes`, `stampValid` and `stampChecked` are
    /// deliberately excluded.
    ///
    /// `receivedBytes` is a cache of how this message arrived, not part of what it says, and
    /// including it would make a round-tripped message unequal to the one it round-tripped from.
    /// **`stampValid`/`stampChecked` are excluded for the same reason and by the same precedent**:
    /// they record what *we* concluded about the message, not what the message *says*. Two messages
    /// with identical content are equal whether or not one of them has been through validation.
    /// Including them would make a validated inbound message unequal to the constructed message it
    /// carries, and the ripple would land in unrelated tests that compare a received message to an
    /// expected one.
    public static func == (lhs: LXMessage, rhs: LXMessage) -> Bool {
        lhs.destinationHash == rhs.destinationHash && lhs.sourceHash == rhs.sourceHash
            && lhs.timestamp == rhs.timestamp && lhs.title == rhs.title
            && lhs.content == rhs.content && lhs.hash == rhs.hash
            && lhs.signature == rhs.signature && lhs.fields == rhs.fields && lhs.stamp == rhs.stamp
    }

    // Explicit memberwise init so `receivedBytes` defaults to `nil` and no existing call site needs
    // to change. Only `unpack` passes a non-nil value. `stampValid`/`stampChecked` default to false
    // (= "never checked"), matching reference's initialisers at `LXMessage.py:157-158`; only
    // `withStampValidation` passes anything else.
    init(destinationHash: Data, sourceHash: Data, timestamp: Double, title: Data, content: Data,
         hash: Data, signature: Data, fields: [MsgPackValue.IntPair], stamp: Data?,
         receivedBytes: Data? = nil, stampValid: Bool = false, stampChecked: Bool = false) {
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.hash = hash
        self.signature = signature
        self.fields = fields
        self.stamp = stamp
        self.receivedBytes = receivedBytes
        self.stampValid = stampValid
        self.stampChecked = stampChecked
    }

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
    ///
    /// A message that came off the wire returns **exactly what it received**, mirroring reference
    /// `message.packed = lxmf_bytes` (lxmf 1.1.0 `LXMessage.py:798`) — a relay must not re-encode
    /// someone else's message, because any legal encoding difference would invalidate their
    /// signature for every downstream hop. Only a locally-created message is packed from its fields.
    public var packed: Data {
        if let receivedBytes { return receivedBytes }
        return destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title,
                                     content: content, fields: fields, stamp: stamp)
    }

    /// A copy of this message with a delivery stamp attached (hash/signature unchanged — the stamp is
    /// not part of the signed payload). The stamp is produced by `LXStamper.generateStamp(messageId: hash, …)`.
    ///
    /// `receivedBytes` is deliberately **not** threaded through. If it were, `packed` would return
    /// the pre-stamp bytes (whatever arrived on the wire without a stamp) and silently discard the
    /// newly-attached stamp. A stamped copy has no prior wire form, so `packed` must re-encode from
    /// fields — which is what falling back to the `receivedBytes == nil` branch of `packed` gives us.
    public func withStamp(_ stamp: Data) -> LXMessage {
        LXMessage(destinationHash: destinationHash, sourceHash: sourceHash, timestamp: timestamp,
                  title: title, content: content, hash: hash, signature: signature, fields: fields, stamp: stamp)
    }

    /// Validate the attached stamp against `targetCost` (workblock derived from this message's hash).
    ///
    /// **Not free, despite being O(1) in `targetCost`.** The cost parameter only sets how many
    /// leading zero bits are required of a single hash; the expensive part is deriving the workblock,
    /// which is a fixed ~3000 HKDF rounds producing 768 KB (`LXStamper.stampWorkblock`) on every
    /// call, at any cost. Order ~60 ms, extrapolated from the ~21 ms measured for the 1000-round
    /// (256 KB) propagation workblock at `LXStamper.swift:22-23`. Reference has the identical
    /// property (`LXMessage.py:288-289` derives the workblock then checks bits), so this is parity,
    /// not a regression — but anyone sizing an inbound flood should budget it rather than assume a
    /// cheap bit-test.
    public func validateStamp(targetCost: Int) -> Bool {
        guard let stamp else { return false }
        return LXStamper.stampValid(stamp: stamp, targetCost: targetCost,
                                    workblock: LXStamper.stampWorkblock(material: hash))
    }

    /// A copy carrying the outcome of a stamp validation: `stampChecked` becomes true and
    /// `stampValid` records the result.
    ///
    /// Mirrors reference's assignment pair in `LXMRouter.lxmf_delivery` (lxmf 1.1.0,
    /// `LXMRouter.py:1865-1869`), which sets `stamp_checked = True` on **both** branches and varies
    /// only `stamp_valid`. Reference mutates the message in place; we return a copy because
    /// `LXMessage` is a value type.
    ///
    /// **`receivedBytes` IS threaded through here**, unlike in `withStamp`. The distinction is that
    /// `withStamp` changes what the message *is* (a new payload element, so the retained wire bytes
    /// would be stale and `packed` must re-encode), whereas this records what we *concluded about*
    /// it — the wire form is unchanged, so dropping `receivedBytes` would force a re-encode of a
    /// received message and could invalidate its signature for any downstream hop.
    public func withStampValidation(valid: Bool) -> LXMessage {
        LXMessage(destinationHash: destinationHash, sourceHash: sourceHash, timestamp: timestamp,
                  title: title, content: content, hash: hash, signature: signature, fields: fields,
                  stamp: stamp, receivedBytes: receivedBytes, stampValid: valid, stampChecked: true)
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
                         hash: hash, signature: signature, fields: fields, stamp: stamp,
                         receivedBytes: data)
    }

    /// Validate the signature against the resolved source identity (the caller resolves it by
    /// `sourceHash`). For a message off the wire this validates the bytes **as received**, matching
    /// reference `signed_part` (lxmf 1.1.0 `LXMessage.py:764`); only a locally-created message, which
    /// has no received form, is validated against re-encoded fields.
    ///
    /// A stamped message still re-packs `payload[:4]`, exactly as reference does at
    /// `LXMessage.py:758` — canonical encoding remains required on that path, by design, not oversight.
    public func validateSignature(source: Identity) -> Bool {
        let hashedPart: Data
        if let receivedBytes, stamp == nil {
            let headerLen = 2 * LXMessage.destinationLength + LXMessage.signatureLength
            hashedPart = destinationHash + sourceHash + Data(receivedBytes.dropFirst(headerLen))
        } else {
            hashedPart = destinationHash + sourceHash
                + LXMessage.payloadBytes(timestamp: timestamp, title: title,
                                         content: content, fields: fields)
        }
        return source.validate(signature: signature, message: hashedPart + Crypto.fullHash(hashedPart))
    }
}
