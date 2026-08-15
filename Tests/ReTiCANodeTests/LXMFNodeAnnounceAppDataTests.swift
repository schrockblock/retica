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

// MARK: - setDisplayName updates state and re-announces

/// `.setDisplayName` must update `state.displayName` AND emit a new `announce` effect carrying
/// the updated name in `appData`. A name change nobody hears is not a name change.
///
/// Anti-vacuity: the assertion is on the `appData` bytes of the re-announce action. Checking only
/// `state.displayName` would pass even if the announce carried `appData: nil` or stale bytes.
@MainActor @Test func setDisplayNameUpdatesStateAndReAnnounces() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    // Register first so deliveryDestinationHash is set.
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.setDisplayName("Bob", stampCost: nil))
    #expect(store.state.displayName == "Bob")
    #expect(store.state.deliveryStampCost == nil)

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
            #expect(parsed.displayName == "Bob")
        }
    }
}

/// `.setDisplayName` must update BOTH `state.displayName` and `state.deliveryStampCost` when a
/// cost is supplied, and the re-announce `appData` must carry both fields.
@MainActor @Test func setDisplayNameWithStampCostUpdatesStateAndReAnnounces() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.setDisplayName("Carol", stampCost: 10))
    #expect(store.state.displayName == "Carol")
    #expect(store.state.deliveryStampCost == 10)

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
            #expect(parsed.displayName == "Carol")
            #expect(parsed.stampCost == 10)
        }
    }
}

/// `.setDisplayName` before `registerDelivery` must update state but must NOT emit an announce
/// (there is no registered delivery destination to announce on).
///
/// Anti-vacuity: exhaustivity is flipped to `.on` before the send so any stray `.announce` action
/// in the effect queue fails teardown. The state mutation is declared inside the `send` trailing
/// closure to satisfy `.on` exhaustivity — it is the observable outcome we expect, not a
/// side-effect we're trying to hide.
@MainActor @Test func setDisplayNameBeforeRegisterDeliveryDoesNotReAnnounce() async {
    let identity = Identity()
    let store = makeAnnounceStore(identity: identity)

    // Do NOT call registerDelivery — deliveryDestinationHash must remain nil.
    store.exhaustivity = .on
    await store.send(.setDisplayName("Dave", stampCost: nil)) {
        $0.displayName = "Dave"
    }
    // Teardown under .on: any stray announce action would fail here because it was
    // not consumed. The trailing closure above accounts for the state mutation; any
    // emitted effect would remain in the queue and fail teardown.
    #expect(store.state.displayName == "Dave")
}

/// `.setDisplayName` with nil clears the name. The re-announce `appData` blob is still emitted
/// (always-pack parity) but `displayName` parses as nil.
@MainActor @Test func setDisplayNameNilClearsNameButStillEmitsBlob() async {
    let identity = Identity()
    // Start with a name pre-set so clearing is observable.
    let store = makeAnnounceStore(identity: identity, displayName: "Eve")

    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)

    let capturedAppData = LockIsolated<Data?>(nil)
    await store.send(.setDisplayName(nil, stampCost: nil))
    #expect(store.state.displayName == nil)

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
        }
    }
}
