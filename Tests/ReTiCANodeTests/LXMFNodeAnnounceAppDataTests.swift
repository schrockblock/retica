import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - Helpers

@MainActor
private func makeAnnounceStore(
    identity: Identity,
    displayName: String? = nil,
    stampCost: Int? = nil
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var node = LXMFNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    node.displayName = displayName
    node.deliveryStampCost = stampCost
    let store = TestStore(initialState: node) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { })
    }
    store.exhaustivity = .off
    return store
}

// MARK: - registerDelivery always emits app-data blob

/// `registerDelivery` with no display name set must still emit an announce whose `appData` is a
/// non-nil, non-empty, parseable blob — matching reference `get_announce_app_data`
/// (LXMF 1.1.0, LXMRouter.py:1034-1050) which calls `msgpack.packb(peer_data)` unconditionally.
///
/// Anti-vacuity: the assertion directly checks `appData` bytes in the emitted announce action,
/// not merely that state changed. An `appData: nil` announce would fail the non-nil check.
@MainActor @Test func registerDeliveryAlwaysEmitsAppDataBlob() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.registerDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        #expect(!blob.isEmpty)
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == nil)
            #expect(parsed.stampCost == nil)
            #expect(parsed.supportsCompression == true)
        }
    }
}

/// `registerDelivery` with a display name pre-set must emit an announce whose `appData` parses
/// back to that exact name.
///
/// Anti-vacuity: the assertion is on the `appData` bytes from the announce *effect*, not on
/// `state.displayName`. An announce emitting `appData: nil` or empty `Data()` would fail
/// `LXMFAnnounceData.parse(_:)` returning nil, and the `parsed.displayName` check would be skipped
/// — but the preceding `#expect(parsed != nil)` would catch it.
@MainActor @Test func registerDeliveryWithDisplayNameEmitsNameInAppData() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity, displayName: "Alice")

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.registerDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.displayName == "Alice")
        }
    }
}

/// `registerDelivery` with a stamp cost in range (1...254) must emit an announce whose `appData`
/// parses back to that cost.
@MainActor @Test func registerDeliveryWithStampCostEmitsCostInAppData() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity, stampCost: 5)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.registerDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = capturedAppData.value
    #expect(blob != nil)
    if let blob {
        let parsed = LXMFAnnounceData.parse(blob)
        #expect(parsed != nil)
        if let parsed {
            #expect(parsed.stampCost == 5)
        }
    }
}

// MARK: - setDisplayName is a setter; announceDelivery is the broadcast

/// `.setDisplayName` must update `state.displayName` and `state.deliveryStampCost` and emit
/// NOTHING. The broadcast is `.announceDelivery`'s job: an unthrottled fan-out on every interface
/// must not be the side effect of a state write, or a `TextField` binding announces per keystroke.
///
/// Anti-vacuity: exhaustivity is flipped to `.on` before the send, so a re-announce effect (the
/// pre-split behaviour) fails teardown. Both state fields are asserted, so a setter that writes
/// only one also fails.
@MainActor @Test func setDisplayNameUpdatesStateAndDoesNotAnnounce() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    // Register first, so deliveryDestinationHash is set and an announce COULD be emitted.
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    store.exhaustivity = .on
    await store.send(.setDisplayName("Bob", stampCost: 10)) {
        $0.displayName = "Bob"
        $0.deliveryStampCost = 10
    }
    #expect(store.state.displayName == "Bob")
    #expect(store.state.deliveryStampCost == 10)
    // Teardown under .on: an announce effect here would be unconsumed and fail.
}

/// `.announceDelivery` must emit an announce whose `appData` carries the name and cost currently
/// in state — i.e. the values a preceding `.setDisplayName` wrote.
///
/// Anti-vacuity: the assertion is on the `appData` bytes of the announce action, not on state.
/// `try #require` fails fast if no announce was emitted, rather than skipping the field checks.
@MainActor @Test func announceDeliveryEmitsTheCurrentNameAndStampCost() async throws {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    await store.send(.setDisplayName("Carol", stampCost: 10))

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.announceDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = try #require(capturedAppData.value, ".announceDelivery must emit app data")
    let parsed = try #require(LXMFAnnounceData.parse(blob))
    #expect(parsed.displayName == "Carol")
    #expect(parsed.stampCost == 10)
}

// MARK: - The stamp cost is range-sanitised at the setter

/// The setter stores a cost only in **1...99** — reference's `set_inbound_stamp_cost` range
/// (LXMRouter.py:444-462, LXMF 1.3.0): `< 1` becomes None, `< STAMP_COST_CAP` (100) is stored,
/// `>= 100` is rejected. 100 itself is rejected, because the comparison is strict.
///
/// This matters because `State.deliveryStampCost` is what the *inbound* half validates against
/// (`LXMFNode.swift`, the `messageDelivered` branch), while the *announce* applies its own
/// `> 0` and below-the-cap gate (`LXMFAnnounceData.pack`). An unsanitised setter let the two disagree:
/// see `lxmfNodeDoesNotEnforceStampsAfterACostOfZero` and
/// `lxmfNodeDoesNotReportAStampValidAfterANegativeCost` for the two measured consequences.
///
/// Anti-vacuity: every boundary is asserted individually and each rejected case is preceded by nil,
/// so a setter that stored the raw value fails on the 0 case, the 100 case, or both. The 1 and 99
/// cases fail any over-eager sanitiser that clamped the range too tightly.
@MainActor @Test func setDisplayNameStoresOnlyStampCostsInTheReferenceRange() async {
    let store = makeAnnounceStore(identity: Identity())

    await store.send(.setDisplayName(nil, stampCost: 1))
    #expect(store.state.deliveryStampCost == 1)          // lower bound: accepted
    await store.send(.setDisplayName(nil, stampCost: 99))
    #expect(store.state.deliveryStampCost == 99)         // upper bound: accepted

    await store.send(.setDisplayName(nil, stampCost: nil))
    #expect(store.state.deliveryStampCost == nil)        // clean slate
    await store.send(.setDisplayName(nil, stampCost: 0))
    #expect(store.state.deliveryStampCost == nil)        // < 1 → None
    await store.send(.setDisplayName(nil, stampCost: -1))
    #expect(store.state.deliveryStampCost == nil)        // < 1 → None
    for rejected in [100, 101, 254, 255] {
        await store.send(.setDisplayName(nil, stampCost: rejected))
        #expect(store.state.deliveryStampCost == nil,    // >= cap → rejected, nothing to keep
                "cost \(rejected) must be rejected")
    }
}

/// A rejected (`>= 100`) cost leaves the previously configured cost in place — and the next
/// announce still carries that previous cost.
///
/// This is reference's exact shape: `set_inbound_stamp_cost` returns False on `>= cap` **without
/// assigning** (LXMRouter.py:453-454, LXMF 1.3.0), so the destination keeps the cost it had.
/// Clearing instead would let one out-of-range settings value silently downgrade a node that had
/// deliberately configured a cost.
///
/// Anti-vacuity: asserts on the announce's `appData` bytes as well as on state. Without the setter
/// sanitisation, the rejected cost is stored and `LXMFAnnounceData.pack`'s own below-the-cap gate emits null —
/// so the parsed cost would be nil and both assertions would fail.
@MainActor @Test func setDisplayNameKeepsThePreviousStampCostWhenANewOneIsRejected() async throws {
    let store = makeAnnounceStore(identity: Identity())
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    await store.send(.setDisplayName("Frank", stampCost: 12))
    await store.send(.setDisplayName("Frank", stampCost: 101))
    #expect(store.state.deliveryStampCost == 12)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.announceDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }
    let blob = try #require(capturedAppData.value, ".announceDelivery must emit app data")
    let parsed = try #require(LXMFAnnounceData.parse(blob))
    #expect(parsed.stampCost == 12)
}

/// `.announceDelivery` before `registerDelivery` must NOT emit an announce (there is no registered
/// delivery destination to announce on).
///
/// Anti-vacuity: exhaustivity is flipped to `.on` before the send so any stray `.announce` action
/// in the effect queue fails teardown.
@MainActor @Test func announceDeliveryBeforeRegisterDeliveryEmitsNothing() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity, displayName: "Dave")

    // Do NOT call registerDelivery — deliveryDestinationHash must remain nil.
    store.exhaustivity = .on
    await store.send(.announceDelivery)
    // Teardown under .on: any emitted announce would remain in the queue and fail.
}

/// `.setDisplayName(nil, ...)` clears the name, and the following `.announceDelivery` still emits
/// the full app-data blob (always-pack parity) with `displayName` parsing as nil.
@MainActor @Test func announceDeliveryAfterClearingTheNameStillEmitsBlob() async throws {
    let identity = Identity()
    // Start with a name pre-set so clearing is observable.
    let store = makeAnnounceStore(identity: identity, displayName: "Eve")

    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    await store.send(.setDisplayName(nil, stampCost: nil))
    #expect(store.state.displayName == nil)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.announceDelivery)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action {
            capturedAppData.setValue(appData)
            return true
        }
        return false
    }

    let blob = try #require(capturedAppData.value, ".announceDelivery must emit app data")
    #expect(!blob.isEmpty)
    let parsed = try #require(LXMFAnnounceData.parse(blob))
    #expect(parsed.displayName == nil)
}

// MARK: - Learning peers from inbound delivery announces

/// The wall-clock instant every test in this section injects via `\.date`, so `learnedAt` is pinnable.
private let learnAnnounceDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Helper: make a store with a pre-seeded `LearnedDestination` for `announcedHash`, whose identity
/// and `appData` are controlled by the caller. Seeding into `endpoint.transport.learned` before the
/// store is built mirrors the way the transport populates `learned` before firing `pathLearned`.
///
/// `announcedHash` and `peerIdentity` are separate parameters on purpose: the production gate
/// compares `announcedHash` against `LXMessage.deliveryHash(identityHash: peerIdentity.hash)`, so a
/// test can only exercise that gate if it can set the two independently.
@MainActor
private func makeLearnPeerStore(
    announcedHash: Data,
    peerIdentity: Identity,
    peerAppData: Data?
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var tcp = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    tcp.transport.learned[announcedHash] = LearnedDestination(
        identity: peerIdentity, appData: peerAppData, ratchet: nil,
        interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    let store = TestStore(initialState: LXMFNode.State(identity: Identity(), endpoint: tcp)) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(learnAnnounceDate)
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { })
    }
    store.exhaustivity = .off
    return store
}

/// A delivery announce with a display name populates `learnedPeers` with that name, keyed by the
/// peer's real `lxmf.delivery` destination hash.
///
/// Anti-vacuity: `#expect(peer != nil)` fails if nothing was stored; `displayName == "Alice"` fails
/// if the wrong field or a nil was stored. The key is the genuine delivery hash, so this also pins
/// that the production gate accepts a correctly-keyed announce rather than merely storing anything.
@MainActor @Test func pathLearnedWithDisplayNameStoresPeerDisplayName() async {
    let peerIdentity = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: peerIdentity.hash)
    let store = makeLearnPeerStore(
        announcedHash: deliveryHash, peerIdentity: peerIdentity,
        peerAppData: LXMFAnnounceData.pack(displayName: "Alice", stampCost: nil))

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: deliveryHash, hops: 1))))

    let peer = store.state.learnedPeers[deliveryHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.displayName == "Alice")
    }
}

/// A delivery announce with a stamp cost populates `learnedPeers` with that cost.
///
/// Anti-vacuity: `stampCost == 7` fails if nil or a different value was stored.
@MainActor @Test func pathLearnedWithStampCostStoresPeerStampCost() async {
    let peerIdentity = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: peerIdentity.hash)
    let store = makeLearnPeerStore(
        announcedHash: deliveryHash, peerIdentity: peerIdentity,
        peerAppData: LXMFAnnounceData.pack(displayName: nil, stampCost: 7))

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: deliveryHash, hops: 1))))

    let peer = store.state.learnedPeers[deliveryHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.stampCost == 7)
    }
}

/// A delivery announce stores ALL FOUR fields: name, cost, compression support, and the wall-clock
/// `learnedAt`. This is the per-field pin — the other tests cover one field each, so without this
/// one a mutation to `supportsCompression` or `learnedAt` would break no test.
///
/// Anti-vacuity: each field is asserted separately against a value that differs from the
/// zero/default it would hold if unwritten (`learnedAt` in particular is compared to the injected
/// date, so storing `Date()` or `.distantPast` fails).
@MainActor @Test func pathLearnedStoresAllFourLearnedPeerFields() async {
    let peerIdentity = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: peerIdentity.hash)
    let store = makeLearnPeerStore(
        announcedHash: deliveryHash, peerIdentity: peerIdentity,
        peerAppData: LXMFAnnounceData.pack(displayName: "Bob", stampCost: 12))

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: deliveryHash, hops: 1))))

    let peer = store.state.learnedPeers[deliveryHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.displayName == "Bob")
        #expect(peer.stampCost == 12)
        #expect(peer.supportsCompression == true)   // pack always emits SF_COMPRESSION
        #expect(peer.learnedAt == learnAnnounceDate)
    }
}

/// An announce whose functionality list omits `SF_COMPRESSION` stores `supportsCompression == false`.
///
/// Paired with `pathLearnedStoresAllFourLearnedPeerFields` (which pins the `true` case), this makes
/// `supportsCompression` a two-sided pin: inverting the stored value flips one of the two and fails.
/// `LXMFAnnounceData.pack` cannot produce this blob — it always emits `SF_COMPRESSION` — so the
/// app-data is built directly.
@MainActor @Test func pathLearnedWithoutCompressionSupportStoresFalse() async {
    let peerIdentity = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: peerIdentity.hash)
    // [display_name, stamp_cost, [9]] — a functionality list without SF_COMPRESSION (0x00).
    let appData = MsgPack.encode(.array([.bin(Data("Zed".utf8)), .null, .array([.uint(9)])]))
    let store = makeLearnPeerStore(
        announcedHash: deliveryHash, peerIdentity: peerIdentity, peerAppData: appData)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: deliveryHash, hops: 1))))

    let peer = store.state.learnedPeers[deliveryHash]
    #expect(peer != nil)
    if let peer {
        #expect(peer.displayName == "Zed")          // proves the blob was parsed, not defaulted
        #expect(peer.supportsCompression == false)
    }
}

/// A propagation-node announce, arriving on the peer's real `lxmf.propagation` destination hash,
/// must NOT be stored in `learnedPeers`.
///
/// The exclusion is now STRUCTURAL, not shape-based: the announced hash is the propagation
/// destination, which cannot equal `deliveryHash(identityHash:)` of the same identity, so the gate
/// rejects it regardless of payload. (The previous revision excluded PN announces by testing
/// `PNAnnounce.parse(appData) == nil`, which leaked for every PN blob that fails that parse — a
/// 6-element announce, reference's own "Insufficient peer data" case at LXMF.py:228, was stored
/// with its timebase misread as a stamp cost.)
///
/// Anti-vacuity: deleting the destination check stores the entry with `stampCost == 1_700_000_000`,
/// failing `#expect(... == nil)`.
@MainActor @Test func pathLearnedWithPNAnnounceOnPropagationHashDoesNotStoreLearnedPeer() async {
    let peerIdentity = Identity()
    let propagationHash = Destination.hash(identityHash: peerIdentity.hash,
                                           appName: LXMessage.appName, aspects: ["propagation"])
    let pnData = PNAnnounce(timebase: 1_700_000_000, nodeState: true,
                            perTransferLimit: 256, perSyncLimit: 10240,
                            targetStampCost: 5, stampCostFlexibility: 1, peeringCost: 3).packed
    let store = makeLearnPeerStore(
        announcedHash: propagationHash, peerIdentity: peerIdentity, peerAppData: pnData)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: propagationHash, hops: 1))))

    #expect(store.state.learnedPeers[propagationHash] == nil)
}

/// An announce from a NON-LXMF application must not be stored. `.pathLearned` fires for every
/// announce on the network regardless of aspect, and `LXMFAnnounceData.parse` accepts every
/// non-empty blob via its legacy raw-UTF-8 path — so without the destination gate a NomadNet node
/// announce would be recorded as an LXMF peer named "NomadNet Node".
///
/// This is the larger of the two failure directions and the one no earlier test covered.
///
/// Anti-vacuity: deleting the destination check stores an entry whose `displayName` is
/// "NomadNet Node", failing `#expect(... == nil)`.
@MainActor @Test func pathLearnedWithForeignAppAnnounceDoesNotStoreLearnedPeer() async {
    let peerIdentity = Identity()
    let foreignHash = Destination.hash(identityHash: peerIdentity.hash,
                                       appName: "nomadnetwork", aspects: ["node"])
    let store = makeLearnPeerStore(
        announcedHash: foreignHash, peerIdentity: peerIdentity,
        peerAppData: Data("NomadNet Node".utf8))

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: foreignHash, hops: 1))))

    #expect(store.state.learnedPeers[foreignHash] == nil)
}

/// A delivery announce with no app-data (nil) must not create a `learnedPeers` entry — the
/// destination gate passes here, so this isolates the nil-app-data guard specifically.
///
/// Anti-vacuity: dropping the guard stores a default-initialized entry, failing `#expect(... == nil)`.
@MainActor @Test func pathLearnedWithNoAppDataDoesNotStoreLearnedPeer() async {
    let peerIdentity = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: peerIdentity.hash)
    let store = makeLearnPeerStore(
        announcedHash: deliveryHash, peerIdentity: peerIdentity, peerAppData: nil)

    await store.send(.endpoint(.delegate(.pathLearned(destinationHash: deliveryHash, hops: 1))))

    #expect(store.state.learnedPeers[deliveryHash] == nil)
}
