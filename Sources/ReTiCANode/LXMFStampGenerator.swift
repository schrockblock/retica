import Foundation
import ComposableArchitecture
import ReTiCA

/// The LXMF stamp searches `LXMFNode` runs from its stamp queue. Live, `deliveryStamp` is
/// `LXStamper.generateStamp` and `propagationPack` is `LXMFPropagation.pack`. A test replaces them to
/// hold a search open, or end it, when it chooses: a real search's duration is random, so asserting
/// the order searches end in against real ones is a race.
///
/// Contract: return the stamp (or the packed container) or nil, and return promptly once the
/// enclosing task is cancelled.
public struct LXMFStampGenerator: Sendable {
    /// A delivery stamp for `messageID` at `cost`.
    public var deliveryStamp: @Sendable (_ messageID: Data, _ cost: Double) async -> Data?
    /// `message` packed for its propagation node: encrypted to `recipient` (and `ratchet` when given),
    /// with a propagation stamp at `cost`. The container bytes.
    public var propagationPack: @Sendable (_ message: LXMessage, _ recipient: Identity, _ ratchet: Data?,
                                           _ timestamp: Double, _ cost: Double) async -> Data?
    /// A peering key over `peeringID` (the peer's identity hash ‖ ours) at `cost`, as
    /// `LXMFServiceNode` mines one for each peer it syncs to. Live: `LXStamper.generatePeeringKey`.
    public var peeringKey: @Sendable (_ peeringID: Data, _ cost: Double) async -> Data?

    public init(deliveryStamp: @escaping @Sendable (_ messageID: Data, _ cost: Double) async -> Data?,
                propagationPack: @escaping @Sendable (_ message: LXMessage, _ recipient: Identity, _ ratchet: Data?,
                                                      _ timestamp: Double, _ cost: Double) async -> Data?,
                peeringKey: @escaping @Sendable (_ peeringID: Data, _ cost: Double) async -> Data? = { id, cost in
                    await LXStamper.generatePeeringKey(peeringId: id, targetCost: cost)
                }) {
        self.deliveryStamp = deliveryStamp
        self.propagationPack = propagationPack
        self.peeringKey = peeringKey
    }
}

extension LXMFStampGenerator: DependencyKey {
    public static let liveValue = LXMFStampGenerator(
        deliveryStamp: { messageID, cost in
            await LXStamper.generateStamp(messageId: messageID, targetCost: cost)
        },
        propagationPack: { message, recipient, ratchet, timestamp, cost in
            await LXMFPropagation.pack(message: message, recipientIdentity: recipient, ratchet: ratchet,
                                       timestamp: timestamp, stampCost: cost)?.propagationPacked
        },
        peeringKey: { id, cost in
            await LXStamper.generatePeeringKey(peeringId: id, targetCost: cost)
        })
    /// The real searches: tests that do not care which generator runs get the live behaviour.
    public static let testValue = liveValue
}

extension DependencyValues {
    /// The LXMF stamp searches `LXMFNode` uses (see `LXMFStampGenerator`).
    public var lxmfStampGenerator: LXMFStampGenerator {
        get { self[LXMFStampGenerator.self] }
        set { self[LXMFStampGenerator.self] = newValue }
    }
}
