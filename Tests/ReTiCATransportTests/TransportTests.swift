import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// C1 shim: the case gained a profile payload; ~54 construction sites in this module
// (including Vectors/RelayCrossValidationTests) predate it and don't care which profile.
// A static func with the case's base name resolves the one-argument spelling.
// TESTS ONLY — production must always pass a profile explicitly.
extension Transport.Action {
    static func interfaceConnected(_ id: InterfaceID) -> Self {
        .interfaceConnected(id, .default)
    }
}

@Test func ringSetInsertReportsNoveltyAndDedups() {
    var set = RingSet(capacity: 3)
    #expect(set.insert(Data([1])) == true)
    #expect(set.insert(Data([1])) == false) // duplicate
    #expect(set.contains(Data([1])) == true)
}

@Test func ringSetEvictsOldestPastCapacity() {
    var set = RingSet(capacity: 2)
    _ = set.insert(Data([1]))
    _ = set.insert(Data([2]))
    _ = set.insert(Data([3]))          // evicts Data([1])
    #expect(set.contains(Data([1])) == false)
    #expect(set.contains(Data([2])) == true)
    #expect(set.contains(Data([3])) == true)
}

@Test func ringSetRemoveForgetsAndAReinsertKeepsItsNewSlot() {
    var set = RingSet(capacity: 2)
    _ = set.insert(Data([1]))
    _ = set.insert(Data([2]))
    #expect(set.remove(Data([1])) == true)
    #expect(set.contains(Data([1])) == false)
    #expect(set.count == 1)
    #expect(set.remove(Data([1])) == false)           // already gone
    #expect(set.insert(Data([1])) == true)            // new again; lands in the removed slot
    #expect(set.contains(Data([1])) == true)          // the stale slot did not evict the fresh insert
    #expect(set.contains(Data([2])) == true)
    _ = set.insert(Data([3]))                         // evicts Data([2]), the oldest live entry
    #expect(set.contains(Data([1])) == true)
    #expect(set.contains(Data([2])) == false)
    #expect(set.contains(Data([3])) == true)
}

@Test func interfaceIDIsHashable() {
    #expect(InterfaceID("a") == InterfaceID("a"))
    #expect(Set([InterfaceID("a"), InterfaceID("a"), InterfaceID("b")]).count == 2)
}

@Test func destinationIsEquatable() {
    let id = Identity()
    let a = Destination(kind: .single, direction: .in, appName: "app", aspects: ["x"], identity: id)
    let b = Destination(kind: .single, direction: .in, appName: "app", aspects: ["x"], identity: id)
    #expect(a == b)
}

@Test func learnedDestinationIsEquatable() {
    let id = Identity()
    let a = LearnedDestination(identity: id, appData: nil, ratchet: nil,
                               interfaceID: InterfaceID("i"), hops: 2, nextHop: nil, announceEmitted: 10)
    let b = a
    #expect(a == b)
}

@Test @MainActor func registersInterfacesAndLocalDestinations() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("i1"))) {
        $0.interfaces = [InterfaceID("i1"): .default]
    }
    await store.send(.registerLocalDestination(dest)) {
        $0.localDestinations = [dest.hash: dest]
    }
    await store.send(.interfaceDisconnected(InterfaceID("i1"))) {
        $0.interfaces = [:]
    }
}

// Builds a raw ANNOUNCE packet (HEADER_1) for a synthetic identity.
private func makeAnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                hops: UInt8, emitted: UInt64, appData: Data? = nil,
                                randomPrefix: Data = Data(repeating: 0xA5, count: 5)) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: randomPrefix)
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: appData)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@Test @MainActor func learnsPathFromAnnounceAndDedups() async {
    let id = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                             hops: 3, emitted: 1000, appData: Data("meta".utf8))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.received(ifID, raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 3)))

    let entry = store.state.learned[destHash]
    #expect(entry?.identity.hash == id.hash)
    #expect(entry?.hops == 3)
    #expect(entry?.interfaceID == ifID)
    #expect(entry?.appData == Data("meta".utf8))
    #expect(entry?.announceEmitted == 1000)

    // Duplicate packet is suppressed (no second pathLearned).
    await store.send(.received(ifID, raw))
}

@Test @MainActor func recencyPrefersNewerThenShorter() async {
    let id = Identity()
    let (older, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2, emitted: 100)
    let (newer, _)        = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 5, emitted: 200)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.received(InterfaceID("i1"), newer))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 5)))
    // Older emission must NOT replace the newer entry.
    await store.send(.received(InterfaceID("i2"), older))
    #expect(store.state.learned[destHash]?.hops == 5)
    #expect(store.state.learned[destHash]?.announceEmitted == 200)
}

@Test @MainActor func olderAnnounceOverALiveInterfaceReplacesARouteStrandedOnAGoneInterface() async {
    let id = Identity()
    let radio = InterfaceID("meshtastic:radio")
    let tcp = InterfaceID("tcp:hub")
    let (older, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2, emitted: 100)
    let (newer, _) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 0, emitted: 200,
                                        randomPrefix: Data(repeating: 0x5A, count: 5))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(radio))
    await store.send(.interfaceConnected(tcp))
    await store.send(.received(radio, newer))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 0)))
    await store.send(.interfaceDisconnected(radio))
    // The hub's answer is older than the radio announce, but the radio is gone.
    await store.send(.received(tcp, older))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash]?.interfaceID == tcp)
    #expect(store.state.reachableLearned(destHash) != nil)
}

@Test @MainActor func seenAnnounceOverALiveInterfaceReplacesARouteStrandedOnAGoneInterface() async {
    let id = Identity()
    let radio = InterfaceID("meshtastic:radio")
    let tcp = InterfaceID("tcp:hub")
    let (overTCP, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2, emitted: 100)
    let (overRadio, _) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 0, emitted: 200,
                                            randomPrefix: Data(repeating: 0x5A, count: 5))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(radio))
    await store.send(.interfaceConnected(tcp))
    await store.send(.received(tcp, overTCP))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.send(.received(radio, overRadio))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 0)))
    await store.send(.interfaceDisconnected(radio))
    // The hub answers a path request with the announce it cached, which we have seen before.
    await store.send(.received(tcp, overTCP))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash]?.interfaceID == tcp)
}

@Test @MainActor func olderAnnounceDoesNotReplaceARouteWhoseInterfaceIsStillConnected() async {
    let id = Identity()
    let radio = InterfaceID("meshtastic:radio")
    let tcp = InterfaceID("tcp:hub")
    let (older, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2, emitted: 100)
    let (newer, _) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 0, emitted: 200,
                                        randomPrefix: Data(repeating: 0x5A, count: 5))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(radio))
    await store.send(.interfaceConnected(tcp))
    await store.send(.received(radio, newer))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 0)))
    await store.send(.received(tcp, older))
    await store.send(.received(tcp, older))   // and its replay
    #expect(store.state.learned[destHash]?.interfaceID == radio)
    #expect(store.state.learned[destHash]?.announceEmitted == 200)
}

@Test @MainActor func ignoresAnnounceForLocalDestination() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    let (raw, destHash) = makeAnnouncePacket(identity: dest.identity!, appName: "app",
                                             aspects: ["me"], hops: 1, emitted: 50)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    await store.send(.received(InterfaceID("i1"), raw)) // announce for ourselves → ignored
    #expect(store.state.learned[destHash] == nil)
}

@Test @MainActor func deliversInboundDataToLocalDestination() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["inbox"],
                           identity: Identity())!
    let plaintext = Data("hello endpoint".utf8)
    let ciphertext = dest.encrypt(plaintext)            // encrypt to our own destination
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: ciphertext)
    let raw = try! packet.packed()

    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    await store.send(.received(InterfaceID("i1"), raw))
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i1"))))
}

@Test @MainActor func dropsDataForUnknownDestination() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
                        payload: Data(repeating: 0xAB, count: 80))
    await store.send(.received(InterfaceID("i1"), try! packet.packed())) // no delegate expected
}

@Test @MainActor func sendRoutesEncryptedPacketToLearnedInterface() async {
    let remote = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeAnnouncePacket(identity: remote, appName: "app", aspects: ["svc"],
                                             hops: 2, emitted: 500)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    // Connect the interface first — reachableLearned now requires interfaces[entry.interfaceID] != nil.
    await store.send(.interfaceConnected(ifID))
    await store.send(.received(ifID, raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    let plaintext = Data("outbound msg".utf8)
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: plaintext))
    await store.receive { action in
        if case let .delegate(.transmit(id, out)) = action { captured.setValue((id, out)); return true }
        return false
    }

    let (outID, outRaw) = captured.value!
    #expect(outID == ifID)
    let outPacket = Packet(raw: outRaw)!
    #expect(outPacket.destinationHash == destHash)
    #expect(remote.decrypt(outPacket.payload) == plaintext) // round-trips
}

@Test @MainActor func sendToUnknownDestinationFails() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let destHash = Data(repeating: 0x22, count: 16)
    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .notLearned)))
}

/// A learned path whose interface has since disconnected is not usable: sending reports
/// interfaceUnavailable rather than building a packet and routing it into the void. The path
/// itself is RETAINED — it becomes usable again when the interface returns (TCP) or the peer
/// re-announces (BLE).
@Test @MainActor func sendToADestinationOnADepartedInterfaceReportsInterfaceUnavailable() async {
    let remote = Identity()
    let ifID = InterfaceID("i0")
    let (raw, destHash) = makeAnnouncePacket(identity: remote, appName: "app", aspects: ["svc"],
                                             hops: 2, emitted: 500)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    // Connect the interface and learn the path.
    await store.send(.interfaceConnected(ifID))
    await store.send(.received(ifID, raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    // Now disconnect the interface — path must be retained.
    await store.send(.interfaceDisconnected(ifID))
    #expect(store.state.learned[destHash] != nil, "entry must survive interface departure (non-destructive)")

    // ABSENCE ASSERTION: .send is the LAST store.send so receivedActions cannot be wiped
    // by a later store.send. After receiving the expected sendFailed, flip to .on — any
    // additional queued action (e.g. a stray .transmit) would fail the test since we call
    // no further receive.
    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .interfaceUnavailable)))
    store.exhaustivity = .on
    // Path must still be present (non-destructive).
    #expect(store.state.learned[destHash] != nil, "entry must still be retained after failed send")
}

/// The happy path is unchanged: a learned destination on a live interface still transmits.
@Test @MainActor func sendToADestinationOnALiveInterfaceStillTransmits() async {
    let remote = Identity()
    let ifID = InterfaceID("i0")
    let (raw, destHash) = makeAnnouncePacket(identity: remote, appName: "app", aspects: ["svc"],
                                             hops: 2, emitted: 500)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(ifID))
    await store.send(.received(ifID, raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    let captured = LockIsolated<InterfaceID?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: Data("hello".utf8)))
    await store.receive { action in
        if case let .delegate(.transmit(id, _)) = action { captured.setValue(id); return true }
        return false
    }
    #expect(captured.value == ifID, "must transmit on the live interface")
}

/// An unknown destination still reports notLearned — the new check must not swallow or
/// re-label the pre-existing case.
@Test @MainActor func sendToAnUnknownDestinationStillReportsNotLearned() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let destHash = Data(repeating: 0x33, count: 16)
    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .notLearned)))
}

@Test @MainActor func announceEmitsValidPayloadPerInterface() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i1"))) { $0.interfaces = [InterfaceID("i1"): .default] }
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }

    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: Data("name".utf8)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }

    let packet = Packet(raw: captured.value!)!
    #expect(packet.packetType == .announce)
    let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                contextFlagSet: packet.contextFlag)
    #expect(parsed?.identity.hash == dest.identity!.hash)
    #expect(parsed?.appData == Data("name".utf8))
}

@Test @MainActor func duplicateDataPacketIsDeduped() async {
    // A DATA packet that arrives twice must only be delivered once.
    // Without the seenPacketHashes guard, the second copy would re-decrypt and re-deliver.
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["dedup"],
                           identity: Identity())!
    let plaintext = Data("dedup-me".utf8)
    let ciphertext = dest.encrypt(plaintext)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: ciphertext)
    let raw = try! packet.packed()

    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }

    // First delivery.
    await store.send(.received(InterfaceID("i1"), raw))
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i1"))))

    // Second copy of the same raw frame — must be dropped by dedup.
    // Switch exhaustivity ON so any spurious delegate action would be caught.
    store.exhaustivity = .on
    await store.send(.received(InterfaceID("i1"), raw)) // no receive step → asserts no action emitted
}

@Test @MainActor func recencyEqualEmissionPrefersFewerHops() async {
    let id = Identity()
    // Two DISTINCT physical announces (same emission time, different random prefixes → different
    // random-blobs, as real announces would have). Equal emission + fewer hops must still replace.
    let (farther, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 6,
                                                 emitted: 300, randomPrefix: Data(repeating: 0x01, count: 5))
    let (closer, _)         = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2,
                                                 emitted: 300, randomPrefix: Data(repeating: 0x02, count: 5))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i1"), farther))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 6)))
    await store.send(.received(InterfaceID("i2"), closer))   // same emission, fewer hops → replaces
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash]?.hops == 2)
}

@Test @MainActor func dropsDataWhenLocalDestinationKindMismatches() async {
    // Use a PLAIN destination (passthrough decrypt) but send a SINGLE-typed packet.
    // Without the kind guard, `.plain.decrypt` would return the payload and deliver it.
    // With the guard in place it's dropped — so the guard is the discriminating line.
    // Exhaustivity ON so any spurious delivery would be caught as an unexpected action.
    let dest = Destination(kind: .plain, direction: .in, appName: "app", aspects: ["plain"])!
    let rawPacket = try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                destinationHash: dest.hash, transportId: nil,
                                payload: Data(repeating: 0xAB, count: 80)).packed()
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    // Exhaustivity on so any spurious delegate action is caught as unexpected. No state delta to
    // supply: `seenPacketHashes` is reference-backed, so its insertion is invisible to TestStore
    // diffing (see RingSet). Writing one here would assert nothing — it cannot fail.
    store.exhaustivity = .on
    await store.send(.received(InterfaceID("i1"), rawPacket))
    // No receive step here: kind mismatch drops the packet — no delegate action must be emitted.
}

@Test @MainActor func routesLinkAddressedPacketAsLinkPacket() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let linkID = Data(repeating: 0xAB, count: 16)
    // A .link-addressed DATA packet (e.g. a keepalive) with a raw 0xFF payload.
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let raw = try! packet.packed()
    let captured = LockIsolated<(Data, Data)?>(nil)
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { action in
        if case let .delegate(.linkPacket(l, _, d)) = action { captured.setValue((l, d)); return true }
        return false
    }
    #expect(captured.value?.0 == linkID)
    #expect(captured.value?.1 == raw)
}

@Test @MainActor func identicalLinkPacketsBypassDedup() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let linkID = Data(repeating: 0xCD, count: 16)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let raw = try! packet.packed()
    // First send → must produce a linkPacket delegate.
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { if case .delegate(.linkPacket) = $0 { return true }; return false }
    // Second send with byte-identical packet → must NOT be deduped; must produce another linkPacket.
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { if case .delegate(.linkPacket) = $0 { return true }; return false }
    // Both receives completed without timing out → dedup was bypassed twice.
}

@Test @MainActor func routesLinkRequestToLocalDestinationAsLinkRequest() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    // A LINKREQUEST (packetType .linkRequest, destType .single) to our local destination.
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    let raw = try! packet.packed()
    let captured = LockIsolated<Data?>(nil)
    let capturedArrival = LockIsolated<InterfaceID?>(nil)
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { action in
        if case let .delegate(.linkRequest(h, arrival, _)) = action {
            captured.setValue(h); capturedArrival.setValue(arrival); return true
        }
        return false
    }
    #expect(captured.value == dest.hash)
    #expect(capturedArrival.value == InterfaceID("i"))
}

@Test @MainActor func linkRequestToUnknownDestinationIsNotSurfaced() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let unknown = Data(repeating: 0x11, count: 16)
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: unknown, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    await store.send(.received(InterfaceID("i"), try! packet.packed()))
    // No local destination registered → the reducer returns .none; no linkRequest delegate.
    // Switch to exhaustive mode so any unhandled pending action (e.g. a spurious .linkRequest
    // emitted without the guard) causes the test to fail on cleanup.
    store.exhaustivity = .on
    // Assert state is unchanged (no crash, no learned/local mutation).
    #expect(store.state.localDestinations.isEmpty)
    #expect(store.state.learned.isEmpty)
}

// Convenience: build a HEADER_1 announce for a synthetic remote identity at the given hop count.
// Returns (raw packet bytes, destinationHash).
private func makeAnnouncePacket(hops: UInt8, emitted: UInt64 = 1000) -> (Data, Data) {
    makeAnnouncePacket(identity: Identity(), appName: "relay", aspects: ["svc"],
                       hops: hops, emitted: emitted)
}

// Convenience: build a HEADER_1 announce for a synthetic remote identity with a specific randomPrefix
// (controls the random hash and thus the blob — different prefix → different announce blob/destHash).
private func makeAnnouncePacket(hops: UInt8, emitted: UInt64 = 1000,
                                randomPrefix: Data) -> (Data, Data) {
    makeAnnouncePacket(identity: Identity(), appName: "relay", aspects: ["svc"],
                       hops: hops, emitted: emitted, randomPrefix: randomPrefix)
}

// MARK: - #4c-2 announce cache

/// Learning a path caches the announce payload verbatim (for later relay path-responses).
@Test @MainActor func learningPathCachesAnnouncePayload() async {
    let (raw, destHash) = makeAnnouncePacket(hops: 2)
    let expectedPayload = Packet(raw: raw)!.payload
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceCache[destHash]?.payload == expectedPayload)
    #expect(store.state.announceCache[destHash]?.contextFlag == false)   // this announce has no ratchet
}

@Test @MainActor func relayRebroadcastsAnnounceWithHeader2AndOurTransportId() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))

    // A genuine-shape HEADER_1 announce for a REMOTE destination, heard on i0 at hops = 2.
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    // Verify exactly 2 interfaces are registered before the announce arrives.
    #expect(store.state.interfaces == [InterfaceID("i0"): .default, InterfaceID("i1"): .default])

    await store.send(.received(InterfaceID("i0"), announceRaw))

    // Drain pathLearned (direct match).
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    // Drain the single re-broadcast transmit.
    let capturedIfID = LockIsolated<InterfaceID?>(nil)
    let capturedRaw = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action {
            capturedIfID.setValue(ifID)
            capturedRaw.setValue(raw)
            return true
        }
        return false
    }
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast

    // Path learned with HEADER_1 fallback: nextHop == destHash.
    #expect(store.state.learned[destHash]?.nextHop == destHash)

    // Exactly one re-broadcast on i1 (NOT i0), HEADER_2, relay's transport_id, hops+1, same payload.
    #expect(capturedIfID.value == InterfaceID("i1"))
    let rb = Packet(raw: capturedRaw.value!)!
    #expect(rb.headerType == .header2)
    #expect(rb.transportType == .transport)
    #expect(rb.transportId == relay.hash)
    #expect(rb.hops == 3)   // received 2 + 1
    #expect(rb.destinationHash == destHash)
    let orig = Packet(raw: announceRaw)!
    #expect(rb.payload == orig.payload)  // payload verbatim (signature intact)
}

@Test @MainActor func leafDoesNotRebroadcast() async {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    // transportIdentity stays nil → leaf mode.
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)

    await store.send(.received(InterfaceID("i0"), announceRaw))
    // Drain the only expected effect (pathLearned); switch exhaustive ON afterward so any
    // spurious transmit left in the queue would cause teardown to fail.
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    store.exhaustivity = .on
    // No transmit pending → exhaustive teardown passes.
    #expect(store.state.learned[destHash]?.nextHop == destHash)  // fallback still applied
}

@Test @MainActor func relayDoesNotRebroadcastForLocalDestinationOrPastHopLimit() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))

    // (a) Announce for a LOCAL destination → not learned, not re-broadcast.
    let localDest = Destination(kind: .single, direction: .in, appName: "local", aspects: ["svc"],
                                identity: Identity())!
    let (localRaw, _) = makeAnnouncePacket(identity: localDest.identity!, appName: "local",
                                           aspects: ["svc"], hops: 1, emitted: 500)
    await store.send(.registerLocalDestination(localDest))

    let sawTransmitA = LockIsolated(false)
    store.exhaustivity = .on
    // Announce packets are no longer inserted into seenPacketHashes (blob-dedup replaced it for
    // announces). A local-dest announce returns early before the blob ring, so state is unchanged.
    await store.send(.received(InterfaceID("i0"), localRaw))
    #expect(sawTransmitA.value == false)

    store.exhaustivity = .off

    // (b) Announce at hops == maxHops-1 → not re-broadcast (hop limit).
    let hopLimit = UInt8(Packet.maxHops) - 1
    let (limitRaw, limitDestHash) = makeAnnouncePacket(hops: hopLimit, emitted: 999)
    let sawTransmitB = LockIsolated(false)
    await store.send(.received(InterfaceID("i0"), limitRaw))
    await store.receive { action in
        if case .delegate(.transmit) = action { sawTransmitB.setValue(true) }
        if case .delegate(.pathLearned) = action { return true }
        return false
    }
    #expect(sawTransmitB.value == false)
    #expect(store.state.learned[limitDestHash]?.nextHop == limitDestHash)  // still learned
}

@Test @MainActor func relayLearnsNextHopFromHeader2Announce() async {
    let relay = Identity()
    let intermediateTid = Data(repeating: 0x42, count: 16)  // simulated upstream relay hash
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))

    // Build a HEADER_2 announce (already relayed by an upstream relay).
    let remoteID = Identity()
    let (_, destHash) = makeAnnouncePacket(identity: remoteID, appName: "app", aspects: ["x"],
                                           hops: 3, emitted: 777)
    let nameHash = Destination.nameHash(appName: "app", aspects: ["x"])
    let randomHash = Announce.randomHash(now: 777, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: remoteID, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    // Wrap as HEADER_2 with intermediateTid as the transport_id.
    let header2Packet = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                               destinationType: .single, context: .none, contextFlag: false, hops: 3,
                               destinationHash: destHash, transportId: intermediateTid, payload: payload)
    let header2Raw = try! header2Packet.packed()

    await store.send(.received(InterfaceID("i0"), header2Raw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // HEADER_2 announce: nextHop == the announce's transportId (the upstream relay).
    #expect(store.state.learned[destHash]?.nextHop == intermediateTid)
}

@Test @MainActor func announceFansOutToAllInterfaces() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i1"))) { $0.interfaces = [InterfaceID("i1"): .default] }
    await store.send(.interfaceConnected(InterfaceID("i2"))) { $0.interfaces = [InterfaceID("i1"): .default, InterfaceID("i2"): .default] }
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }

    let seen = LockIsolated<Set<InterfaceID>>([])
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    // Two interfaces → two transmits.
    for _ in 0..<2 {
        await store.receive { action in
            if case let .delegate(.transmit(id, _)) = action { seen.withValue { $0.insert(id); return () }; return true }
            return false
        }
    }
    #expect(seen.value == [InterfaceID("i1"), InterfaceID("i2")])
}

// MARK: - Task 4b-2 helpers

/// Build a raw HEADER_2 DATA packet addressed to destHash, naming transportId as the next hop.
private func makeHeader2DataPacket(transportId: Data, destHash: Data, hops: UInt8,
                                   payload: Data) -> Data {
    let p = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                   destinationType: .single, context: .none, contextFlag: false, hops: hops,
                   destinationHash: destHash, transportId: transportId, payload: payload)
    return try! p.packed()
}

/// Build a raw HEADER_2 ANNOUNCE for remoteID, carrying intermediateTid as its transport_id.
/// Used to seed a learned path where nextHop == intermediateTid.
private func makeHeader2AnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                       hops: UInt8, emitted: UInt64,
                                       transportId: Data) -> (Data, Data) {
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xB3, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: transportId, payload: payload)
    return (try! packet.packed(), destHash)
}

/// Returns a leaf store with a learned path where nextHop == relayHash (via-relay).
/// The path is seeded by driving a HEADER_2 announce with transportId = relayHash.
@MainActor
private func storeWithLearnedPathViaRelay() async -> (TestStore<Transport.State, Transport.Action>, Data, Data) {
    let remote = Identity()
    let relayHash = Data(repeating: 0x42, count: 16)
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeHeader2AnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["via-relay"], hops: 2,
                                                     emitted: 1000, transportId: relayHash)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(ifID))
    await store.send(.received(ifID, raw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    return (store, destHash, relayHash)
}

/// Returns a leaf store with a learned path where nextHop == destHash (direct).
/// Seeded via a HEADER_1 announce.
@MainActor
private func storeWithLearnedDirectPath() async -> (TestStore<Transport.State, Transport.Action>, Data) {
    let remote = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeAnnouncePacket(identity: remote, appName: "app", aspects: ["direct"],
                                              hops: 1, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(ifID))
    await store.send(.received(ifID, raw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    return (store, destHash)
}

/// Returns a relay-mode store where the relay knows dest DIRECTLY (nextHop == destHash).
/// Returns (store, relayIdentity, destHash, outInterfaceID).
@MainActor
private func relayStoreKnowingDestDirectly() async -> (TestStore<Transport.State, Transport.Action>,
                                                        Identity, Data, InterfaceID) {
    let relay = Identity()
    let remote = Identity()
    let outIf = InterfaceID("i-out")
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                      aspects: ["dest-direct"], hops: 1, emitted: 2000)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(outIf))
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(outIf, announceRaw))
    // Drain pathLearned + rebroadcast (relay mode with 1 interface produces no rebroadcast since
    // we'd only send back to the same interface — but relay re-broadcasts to OTHER interfaces only).
    // The relay has only one interface (outIf) so no rebroadcast effect is emitted.
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    return (store, relay, destHash, outIf)
}

/// Returns a relay-mode store where the relay knows dest via ANOTHER relay (nextHop != destHash).
/// Returns (store, relayIdentity, destHash, nextRelayHash, outInterfaceID).
@MainActor
private func relayStoreKnowingDestViaAnotherRelay() async -> (TestStore<Transport.State, Transport.Action>,
                                                               Identity, Data, Data, InterfaceID) {
    let relay = Identity()
    let remote = Identity()
    let nextRelay = Data(repeating: 0x55, count: 16)
    let outIf = InterfaceID("i-out")
    let (announceRaw, destHash) = makeHeader2AnnouncePacket(identity: remote, appName: "app",
                                                             aspects: ["dest-via-relay2"], hops: 3,
                                                             emitted: 3000, transportId: nextRelay)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(outIf))
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(outIf, announceRaw))
    // Drain pathLearned + possible rebroadcast (relay may rebroadcast but only interface is outIf
    // so rebroadcast would go back to same interface; relay only sends to OTHER interfaces → none).
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    return (store, relay, destHash, nextRelay, outIf)
}

// MARK: - Task 4b-2 tests

@Test @MainActor func originatorSendsHeader2WhenPathViaRelay() async {
    let (store, destHash, relayHash) = await storeWithLearnedPathViaRelay()
    let captured = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: Data("hi".utf8)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header2)
    #expect(p.transportType == .transport)
    #expect(p.transportId == relayHash)
    #expect(p.destinationHash == destHash)
    #expect(p.hops == 0)
}

@Test @MainActor func originatorSendsHeader1WhenDirect() async {
    let (store, destHash) = await storeWithLearnedDirectPath()
    let captured = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: Data("hi".utf8)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header1)
    #expect(p.transportId == nil)
}

/// A store that learned `dest` from a HEADER_2 announce carrying `nextHop` at on-wire `hops`;
/// in relay mode when `relay` is given.
@MainActor
private func storeWithPathAnnouncedVia(_ nextHop: Data, hops: UInt8, relay: Identity? = nil) async
    -> (TestStore<Transport.State, Transport.Action>, Data) {
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeHeader2AnnouncePacket(identity: Identity(), appName: "app",
                                                     aspects: ["via-\(hops)"], hops: hops,
                                                     emitted: 1000, transportId: nextHop)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(ifID))
    if let relay { await store.send(.setTransportIdentity(relay)) }
    await store.send(.received(ifID, raw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.nextHop == nextHop)
    #expect(store.state.learned[destHash]?.hops == hops)
    return (store, destHash)
}

@MainActor
private func sentPacket(_ store: TestStore<Transport.State, Transport.Action>, _ destHash: Data) async -> Packet {
    let captured = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: Data("hi".utf8)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    return Packet(raw: captured.value!)!
}

/// A local client of the next hop (a propagation node behind a shared rnsd): rnsd passes its
/// announce on as HEADER_2, transport_id = rnsd, on-wire hops 0 — reference hops 1. Reference
/// inserts a transport header only for hops > 1 (`Transport.outbound`), so it is HEADER_1.
@Test @MainActor func originatorSendsHeader1ToALocalClientOfTheNextHop() async {
    let (store, destHash) = await storeWithPathAnnouncedVia(Data(repeating: 0xB4, count: 16), hops: 0)
    let p = await sentPacket(store, destHash)
    #expect(p.headerType == .header1)
    #expect(p.transportType == .broadcast)
    #expect(p.transportId == nil)
    #expect(p.destinationHash == destHash)
}

/// One on-wire hop (reference hops 2) is a real relay: HEADER_2 to the next hop, unchanged.
@Test @MainActor func originatorSendsHeader2AtOneOnWireHop() async {
    let relayHash = Data(repeating: 0x43, count: 16)
    let (store, destHash) = await storeWithPathAnnouncedVia(relayHash, hops: 1)
    let p = await sentPacket(store, destHash)
    #expect(p.headerType == .header2)
    #expect(p.transportId == relayHash)
}

/// The relay's half of the same rule (reference `Transport.inbound`, remaining_hops == 1 strips
/// the transport header): a destination this relay learned at on-wire hops 0 behind another
/// transport instance is the final hop, so the packet goes out HEADER_1.
@Test @MainActor func relayForwardsAsHeader1ToALocalClientOfTheNextHop() async {
    let relay = Identity()
    let (store, destHash) = await storeWithPathAnnouncedVia(Data(repeating: 0xB4, count: 16), hops: 0,
                                                            relay: relay)
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 1,
                                        payload: Data([4, 2]))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let f = Packet(raw: captured.value!)!
    #expect(f.headerType == .header1)
    #expect(f.transportId == nil)
    #expect(f.hops == 2)
    #expect(f.payload == Data([4, 2]))
}

@Test @MainActor func relayForwardsFinalHopAsHeader1() async {
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 1,
                                        payload: Data([1, 2, 3]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action { captured.setValue((ifID, raw)); return true }
        return false
    }
    #expect(captured.value?.0 == outIf)
    let f = Packet(raw: captured.value!.1)!
    #expect(f.headerType == .header1)
    #expect(f.transportType == .broadcast)
    #expect(f.transportId == nil)
    #expect(f.hops == 2)
    #expect(f.destinationHash == destHash)
    #expect(f.payload == Data([1, 2, 3]))
}

@Test @MainActor func relayForwardsOnwardAsHeader2ToNextHop() async {
    let (store, relay, destHash, nextRelay, _) = await relayStoreKnowingDestViaAnotherRelay()
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 0,
                                        payload: Data([9]))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let f = Packet(raw: captured.value!)!
    #expect(f.headerType == .header2)
    #expect(f.transportId == nextRelay)
    #expect(f.hops == 1)
    #expect(f.payload == Data([9]))
}

@Test @MainActor func relayDropsWhenNoPathAndLeafDoesNotForward() async {
    // (a) Relay mode, transport_id == us, but NO learned path for dest → no transmit.
    let relay = Identity()
    let destHash = Data(repeating: 0x77, count: 16)
    let storeA = TestStore(initialState: Transport.State()) { Transport() }
    storeA.exhaustivity = .off
    await storeA.send(.interfaceConnected(InterfaceID("i0")))
    await storeA.send(.setTransportIdentity(relay))
    let inboundA = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 1,
                                          payload: Data([0xAA]))
    // No state delta to supply: `seenPacketHashes` is reference-backed, so its insertion is
    // invisible to TestStore diffing (see RingSet). Exhaustivity catches a stray transmit.
    storeA.exhaustivity = .on
    await storeA.send(.received(InterfaceID("i0"), inboundA))

    // (b) Leaf mode (transportIdentity == nil), HEADER_2 packet with learned path → no transmit.
    // Even with a learned path, a leaf must not forward (requires relay mode).
    let remoteB = Identity()
    let ifB = InterfaceID("i-leaf-out")
    let (announceRawB, destHashB) = makeAnnouncePacket(identity: remoteB, appName: "app",
                                                        aspects: ["leaf-drop"], hops: 1, emitted: 8000)
    let storeB = TestStore(initialState: Transport.State()) { Transport() }
    storeB.exhaustivity = .off
    await storeB.send(.interfaceConnected(ifB))
    // transportIdentity stays nil → leaf mode
    await storeB.send(.received(ifB, announceRawB))
    await storeB.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    // With a learned path: leaf would forward if transportIdentity guard is removed.
    let inboundB = makeHeader2DataPacket(transportId: Data(repeating: 0xDE, count: 16),
                                          destHash: destHashB, hops: 1, payload: Data([0xBB]))
    storeB.exhaustivity = .on
    await storeB.send(.received(InterfaceID("i0"), inboundB))
    // No transmit: leaf mode with no transportIdentity must drop the relay block entirely.

    // (c) Hop limit: relay mode, transport_id == us, path known, but hops == maxHops-1 → no transmit.
    let relay2 = Identity()
    let remote = Identity()
    let outIf = InterfaceID("i-out")
    let (announceRaw, destHashC) = makeAnnouncePacket(identity: remote, appName: "app",
                                                       aspects: ["hop-limit"], hops: 1, emitted: 9000)
    let storeC = TestStore(initialState: Transport.State()) { Transport() }
    storeC.exhaustivity = .off
    await storeC.send(.interfaceConnected(outIf))
    await storeC.send(.setTransportIdentity(relay2))
    await storeC.send(.received(outIf, announceRaw))
    await storeC.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    let maxHops = UInt8(Packet.maxHops) - 1  // 127; +1 == 128 == maxHops → blocked
    let inboundC = makeHeader2DataPacket(transportId: relay2.hash, destHash: destHashC, hops: maxHops,
                                          payload: Data([0xCC]))
    storeC.exhaustivity = .on
    await storeC.send(.received(InterfaceID("i0"), inboundC))
}

@Test @MainActor func localDestinationDataStillDeliveredInRelayMode() async {
    // Regression: a relay with a local destination still receives data packets addressed to it.
    let relay = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["local"],
                           identity: Identity())!
    let plaintext = Data("still works".utf8)
    let ciphertext = dest.encrypt(plaintext)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: ciphertext)
    let raw = try! packet.packed()
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.setTransportIdentity(relay))
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    await store.send(.received(InterfaceID("i1"), raw))
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i1"))))
}

// MARK: - Task 4b-2 tests (byte-fidelity + E2E)

@Test @MainActor func relayForwardBytesMatchRnsRewrite() async {
    // Relay onward (HEADER_2 → next hop): RNS new_raw = raw[0:1] ‖ (hops+1) ‖ nextHop ‖ raw[18:].
    // HEADER_2 layout: flags(1) ‖ hops(1) ‖ transportId(16) ‖ destHash(16) ‖ context(1) ‖ payload.
    // So raw[18:] = destHash onward. Offset verified against Packet.swift packed() serialization.
    // This is a genuine cross-implementation wire check (our output vs RNS's documented raw formula).
    let (store, relay, destHash, nextRelay, _) = await relayStoreKnowingDestViaAnotherRelay()
    store.exhaustivity = .off
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 2,
                                        payload: Data([7, 7]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action {
            captured.setValue((ifID, raw))
            return true
        }
        return false
    }
    // Expected per RNS Transport.py:1605-1608: keep flags byte, hops+1, transport_id = nextHop (16B),
    // then destHash ‖ context ‖ payload verbatim (raw[18:]).
    var expected = Data(inbound.prefix(1))               // flags byte (unchanged → HEADER_2)
    expected.append(UInt8(3))                            // hops = 2 + 1
    expected.append(contentsOf: nextRelay)               // new transport_id (16 bytes)
    expected.append(contentsOf: inbound[18...])          // destHash(16) ‖ context(1) ‖ payload
    #expect(captured.value?.1 == expected)
    // Also verify the forwarded packet goes out on the learned interface.
    let forwarded = Packet(raw: captured.value!.1)!
    #expect(forwarded.headerType == .header2)
    #expect(forwarded.transportId == nextRelay)
}

@Test @MainActor func relayFinalHopBytesMatchRnsRewrite() async {
    // Relay final hop (HEADER_2 → HEADER_1 direct): RNS Transport.py:1609-1614
    //   new_flags = HEADER_1<<6 | BROADCAST<<4 | (flags & 0x0F);  new_raw = new_flags ‖ (hops+1) ‖ raw[18:]
    // i.e. header/context/transport bits zeroed, destType+packetType kept; transport_id STRIPPED, payload verbatim.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()   // nextHop == destHash
    store.exhaustivity = .off
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 4,
                                        payload: Data([9, 9]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action {
            captured.setValue((ifID, raw))
            return true
        }
        return false
    }
    var expected = Data([inbound.first! & 0x0F])         // HEADER_1(0)<<6 | BROADCAST(0)<<4 | (flags & 0x0F)
    expected.append(UInt8(5))                            // hops = 4 + 1
    expected.append(contentsOf: inbound[18...])          // destHash(16) ‖ context(1) ‖ payload — transport_id stripped
    #expect(captured.value?.1 == expected)
    #expect(captured.value?.0 == outIf)
    let forwarded = Packet(raw: captured.value!.1)!
    #expect(forwarded.headerType == .header1)
    #expect(forwarded.transportId == nil)
}

// MARK: - Task 4b-2b helpers

/// Build a raw HEADER_2 LINKREQUEST packet addressed to destHash, naming transportId as the next hop.
/// Payload shape: ephemeral(64) + signalling(3) bytes, matching the RNS link-request wire format.
private func makeHeader2LinkRequestPacket(transportId: Data, destHash: Data, hops: UInt8,
                                          payload: Data) -> Data {
    let p = Packet(headerType: .header2, packetType: .linkRequest, transportType: .transport,
                   destinationType: .single, context: .none, contextFlag: false, hops: hops,
                   destinationHash: destHash, transportId: transportId, payload: payload)
    return try! p.packed()
}

// MARK: - Task 4b-2b tests

@Test @MainActor func relayForwardsLinkRequestAndRecordsLinkTable() async {
    // Relay knows dest D directly (nextHop == D). Inbound HEADER_2 LINKREQUEST, transport_id == R.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])   // ephemeral(64) + signalling(3)
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { action in
        if case let .delegate(.transmit(i, r)) = action { captured.setValue((i, r)); return true }
        return false
    }
    // A linkTable entry keyed by the LINKREQUEST's link_id, rcvdIf = arrival, nhIf = toward dest.
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    #expect(store.state.linkTable[linkID]?.rcvdIf == InterfaceID("in"))
    #expect(store.state.linkTable[linkID]?.nhIf == outIf)
    // Forwarded HEADER_1 LINKREQUEST toward the dest, on outIf.
    #expect(captured.value?.0 == outIf)
    let f = Packet(raw: captured.value!.1)!
    #expect(f.headerType == .header1)
    #expect(f.packetType == .linkRequest)
    #expect(f.destinationHash == destHash)
    #expect(Link.linkID(requestPacket: f) == linkID)     // same link_id after the rewrite
}

@Test @MainActor func dataForwardStillWorksAfterHelperExtraction() async {
    // Regression: the .data forward (refactored to use forwardTowardDest) still produces the same bytes.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 1,
                                        payload: Data([1, 2, 3]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action { captured.setValue((ifID, raw)); return true }
        return false
    }
    // Must still be a HEADER_1 final-hop forward with hops+1 and payload verbatim.
    #expect(captured.value?.0 == outIf)
    let f = Packet(raw: captured.value!.1)!
    #expect(f.headerType == .header1)
    #expect(f.transportType == .broadcast)
    #expect(f.transportId == nil)
    #expect(f.hops == 2)
    #expect(f.destinationHash == destHash)
    #expect(f.payload == Data([1, 2, 3]))
}

@Test @MainActor func threeNodeRelayDeliversMessageEndToEnd() async {
    // A[ar], R[ar,rb] relay, B[rb]. Hand-pump .transmit frames between them.
    // B registers D (with private key so B can decrypt), announces D.
    // Pump B→R→A so A learns D via R; then A.send("hello") → pump A→R→B.
    // REQUIRED assertion: B surfaces exactly one .received(destinationHash: D, plaintext: "hello").

    let rIdentity = Identity()
    let ifAR = InterfaceID("ar")
    let ifRB = InterfaceID("rb")

    // Node A: leaf on interface "ar".
    let storeA = TestStore(initialState: Transport.State()) { Transport() }
    storeA.exhaustivity = .off
    await storeA.send(.interfaceConnected(ifAR))

    // Node R: relay with both interfaces.
    let storeR = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
    }
    storeR.exhaustivity = .off
    await storeR.send(.interfaceConnected(ifAR))
    await storeR.send(.interfaceConnected(ifRB))
    await storeR.send(.setTransportIdentity(rIdentity))

    // Node B: leaf on interface "rb", with a local SINGLE destination D (private key present).
    let destB = Destination(kind: .single, direction: .in, appName: "relay", aspects: ["e2e"],
                            identity: Identity())!
    let storeB = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    storeB.exhaustivity = .off
    await storeB.send(.interfaceConnected(ifRB))
    await storeB.send(.registerLocalDestination(destB))

    // Step 1: B announces D → capture the frame emitted on "rb".
    let bAnnounceRaw = LockIsolated<Data?>(nil)
    await storeB.send(.announce(destinationHash: destB.hash, appData: nil))
    await storeB.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifRB {
            bAnnounceRaw.setValue(raw)
            return true
        }
        return false
    }

    // Step 2: Deliver B's announce to R on "rb". R (relay) learns D (nextHop == D.hash)
    // and re-broadcasts on "ar" (the other interface, since relay excludes source interface).
    let rRebroadcastRaw = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifRB, bAnnounceRaw.value!))
    await storeR.receive { action in
        if case .delegate(.pathLearned) = action { return true }
        return false
    }
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifAR {
            rRebroadcastRaw.setValue(raw)
            return true
        }
        return false
    }
    await storeR.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast

    // Step 3: Deliver R's re-broadcast (HEADER_2 with R's hash as transport_id) to A on "ar".
    // A learns D with nextHop == R.hash, interfaceID == "ar".
    await storeA.send(.received(ifAR, rRebroadcastRaw.value!))
    await storeA.receive { action in
        if case .delegate(.pathLearned) = action { return true }
        return false
    }
    #expect(storeA.state.learned[destB.hash]?.nextHop == rIdentity.hash)

    // Step 4: A sends "hello" to D → emits HEADER_2 (transportId = R.hash) on "ar".
    let aToRRaw = LockIsolated<Data?>(nil)
    let plaintext = Data("hello".utf8)
    await storeA.send(.send(destinationHash: destB.hash, plaintext: plaintext))
    await storeA.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifAR {
            aToRRaw.setValue(raw)
            return true
        }
        return false
    }
    let aPacket = Packet(raw: aToRRaw.value!)!
    #expect(aPacket.headerType == .header2)
    #expect(aPacket.transportId == rIdentity.hash)
    #expect(aPacket.destinationHash == destB.hash)

    // Step 5: Deliver A's HEADER_2 to R on "ar". R forwards as HEADER_1 to B on "rb".
    let rToBRaw = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifAR, aToRRaw.value!))
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifRB {
            rToBRaw.setValue(raw)
            return true
        }
        return false
    }
    let rPacket = Packet(raw: rToBRaw.value!)!
    #expect(rPacket.headerType == .header1)
    #expect(rPacket.destinationHash == destB.hash)

    // Step 6: Deliver R's HEADER_1 to B on "rb". B decrypts and surfaces the exact plaintext.
    // This proves the encrypted payload survived the full relay chain A→R→B.
    await storeB.send(.received(ifRB, rToBRaw.value!))
    await storeB.receive(.delegate(.received(destinationHash: destB.hash, plaintext: plaintext, packetHash: rPacket.packetHash, interfaceID: ifRB)))
}

// MARK: - Task 4b-2b-t3 helpers

/// Build a HEADER_1 .link-addressed packet (destType == .link, destHash == linkID).
/// This is the wire shape of LRPROOF and all established link traffic (keepalive, data, close).
private func makeLinkPacket(linkID: Data, hops: UInt8, payload: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .none, contextFlag: false, hops: hops,
                   destinationHash: linkID, transportId: nil, payload: payload)
    return try! p.packed()
}

/// Build a relay store whose linkTable already contains one entry:
///   linkTable[link_id] = (rcvdIf: rcvdIf, nhIf: nhIf)
/// The link_id is synthesised from a HEADER_2 LINKREQUEST that the relay would have received;
/// we seed it directly into initial state so the test is self-contained and does not depend
/// on the Task-2 flow path.
/// Returns (store, linkID).
@MainActor
private func relayHostingLinkTableEntry(rcvdIf: String, nhIf: String)
    async -> (TestStore<Transport.State, Transport.Action>, Data) {
    let linkID = Data(repeating: 0xEE, count: 16)   // synthetic link_id (16-byte dest hash)
    var initialState = Transport.State()
    initialState.interfaces = [InterfaceID(rcvdIf): .default, InterfaceID(nhIf): .default]
    initialState.linkTable[linkID] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID(rcvdIf), nhIf: InterfaceID(nhIf))
    let store = TestStore(initialState: initialState) { Transport() }
    store.exhaustivity = .off
    return (store, linkID)
}

// MARK: - Task 4b-2b-t3 tests

@Test @MainActor func relayForwardsLinkPacketTowardDest() async {
    // linkTable[link_id] = (rcvdIf: "ar", nhIf: "rb"). A link packet arriving on "ar" → forwarded out "rb".
    let (store, linkID) = await relayHostingLinkTableEntry(rcvdIf: "ar", nhIf: "rb")
    store.exhaustivity = .off
    let lp = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([1, 2, 3]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("ar"), lp))
    await store.receive { action in
        if case let .delegate(.transmit(i, r)) = action { captured.setValue((i, r)); return true }
        return false
    }
    #expect(captured.value?.0 == InterfaceID("rb"))
    let f = Packet(raw: captured.value!.1)!
    #expect(f.hops == 1)
    #expect(f.destinationType == .link)
    #expect(f.destinationHash == linkID)
    #expect(f.payload == Data([1, 2, 3]))
}

@Test @MainActor func relayForwardsLinkPacketTowardInitiator() async {
    // Same entry; a packet arriving on "rb" (nhIf) → forwarded out "ar" (rcvdIf).
    let (store, linkID) = await relayHostingLinkTableEntry(rcvdIf: "ar", nhIf: "rb")
    store.exhaustivity = .off
    let lp = makeLinkPacket(linkID: linkID, hops: 1, payload: Data([4, 5, 6]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("rb"), lp))
    await store.receive { action in
        if case let .delegate(.transmit(i, r)) = action { captured.setValue((i, r)); return true }
        return false
    }
    #expect(captured.value?.0 == InterfaceID("ar"))
    let f = Packet(raw: captured.value!.1)!
    #expect(f.hops == 2)
    #expect(f.destinationType == .link)
    #expect(f.destinationHash == linkID)
    #expect(f.payload == Data([4, 5, 6]))
}

@Test @MainActor func unknownLinkIdSurfacesLinkPacketDelegate() async {
    // No linkTable entry for this link_id → the linkPacket delegate is emitted (not forwarded).
    // This also covers leaf mode (linkTable always empty).
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let unknownLinkID = Data(repeating: 0x77, count: 16)
    let lp = makeLinkPacket(linkID: unknownLinkID, hops: 0, payload: Data([0xAB]))
    let captured = LockIsolated<(Data, Data)?>(nil)
    await store.send(.received(InterfaceID("i"), lp))
    await store.receive { action in
        if case let .delegate(.linkPacket(l, _, d)) = action { captured.setValue((l, d)); return true }
        return false
    }
    #expect(captured.value?.0 == unknownLinkID)
    #expect(captured.value?.1 == lp)
}

// MARK: - Task F13 tests (relay link shadow protection)

@Test @MainActor func reflectedLinkRequestForOurOwnLinkIsNotTabled() async {
    // A relay that has opened its OWN link (registered its linkID) must NOT create a relay
    // linkTable entry for a reflected HEADER_2 copy of that request — doing so shadows the link.
    let (store, relay, destHash, _) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    // We are an endpoint of this link.
    await store.send(.registerLocalLink(linkID))
    // The attacker reflects our own request back to us as a relay request.
    await store.send(.received(InterfaceID("in"), lr))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID] == nil,
            "a reflection of our own LINKREQUEST must not be tabled as relay traffic")
    await store.finish()
}

@Test @MainActor func linkPacketForOurOwnLinkDeliversLocallyNotForwarded() async {
    // Even if a relay entry exists for a linkID we own, an inbound link packet for it must be
    // delivered locally (.linkPacket), never forwarded (.transmit).
    let (store, linkID) = await relayHostingLinkTableEntry(rcvdIf: "ar", nhIf: "rb")
    store.exhaustivity = .off
    await store.send(.registerLocalLink(linkID))
    let lp = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([1, 2, 3]))
    let sawLocal = LockIsolated<Bool>(false)
    let sawForward = LockIsolated<Bool>(false)
    await store.send(.received(InterfaceID("ar"), lp))
    await store.receive { action in
        if case .delegate(.linkPacket) = action { sawLocal.setValue(true); return true }
        if case .delegate(.transmit) = action { sawForward.setValue(true); return true }
        return false
    }
    #expect(sawLocal.value == true, "our own link's packet must be delivered locally")
    #expect(sawForward.value == false, "our own link's packet must not be forwarded")
    await store.finish()
}

@Test @MainActor func genuineRelayStillTablesWhenLinkIsNotOurs() async {
    // A non-local linkID is still tabled and forwarded — the fix must not break real relaying.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    // Register some UNRELATED local link, to prove the guard keys on the specific linkID.
    await store.send(.registerLocalLink(Data(repeating: 0xAB, count: 16)))
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    let forwarded = LockIsolated<Bool>(false)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { action in
        if case .delegate(.transmit) = action { forwarded.setValue(true); return true }
        return false
    }
    #expect(store.state.linkTable[linkID]?.rcvdIf == InterfaceID("in"))
    #expect(store.state.linkTable[linkID]?.nhIf == outIf)
    #expect(forwarded.value == true)
    await store.finish()
}

// MARK: - Task 4 (link_id parity cross-validation)

@Test @MainActor func linkIDParityAcrossHeader2ToHeader1Rewrite() async {
    // Wire-compat guarantee: link_id is header-independent (matches RNS link_id_from_lr_packet).
    // Build an initiator HEADER_2 LINKREQUEST (transport_id = relay R), feed it through the relay
    // (Task 2 forward path), and assert that all three independently derived link_ids agree:
    //   Link.linkID(initiatorHeader2) == Link.linkID(relayForwardedHeader1) == linkTable key.
    //
    // This proves that after the relay rewrites HEADER_2 → HEADER_1 (stripping transport_id,
    // incrementing hops), the deterministic link_id computed from the packet's hashable part
    // remains byte-identical — so all three nodes agree on the link_id without coordination.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off

    // Build a valid LINKREQUEST payload: ephemeral public key (64 bytes) + signalling (3 bytes).
    let ephemeral = Identity()
    let lrPayload = ephemeral.publicKey + Link.signallingBytes

    // Initiator's HEADER_2 LINKREQUEST (transport_id = relay.hash).
    let header2LR = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash,
                                                  hops: 0, payload: lrPayload)
    let header2Packet = Packet(raw: header2LR)!
    let initiatorLinkID = Link.linkID(requestPacket: header2Packet)

    // Feed it through the relay's Task-2 forward path → relay records linkTable + emits HEADER_1.
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), header2LR))
    await store.receive { action in
        if case let .delegate(.transmit(i, r)) = action { captured.setValue((i, r)); return true }
        return false
    }

    // The forwarded HEADER_1 LINKREQUEST (transport_id stripped, hops+1).
    let forwardedRaw = captured.value!.1
    let forwardedPacket = Packet(raw: forwardedRaw)!
    let forwardedLinkID = Link.linkID(requestPacket: forwardedPacket)

    // The linkTable key the relay stored.
    let linkTableKey = store.state.linkTable.keys.first!

    // All three agree — header-independent link_id is the wire-compat guarantee.
    #expect(forwardedPacket.headerType == .header1)
    #expect(forwardedPacket.transportId == nil)
    #expect(initiatorLinkID == forwardedLinkID)
    #expect(initiatorLinkID == linkTableKey)
    #expect(captured.value?.0 == outIf)
}

// MARK: - 4b-3a announce random-blob anti-replay

/// A relay setup helper: two interfaces (i0 arrival, i1 onward) + our transport identity.
@MainActor
private func makeRelayStore(_ relay: Identity) async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    return store
}

/// An exact replay of an announce is dropped by blob-dedup: no second path learn AND (in relay
/// mode, where every fresh announce is re-broadcast) no second re-broadcast.
@Test @MainActor func exactReplayAnnounceIsDroppedAndNotRebroadcast() async {
    let id = Identity()
    let (raw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                             hops: 2, emitted: 1000)
    let store = await makeRelayStore(Identity())
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // first re-broadcast
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast
    // Exact replay → same blob → dropped: no pathLearned, no re-broadcast.
    await store.send(.received(InterfaceID("i0"), raw))
    store.exhaustivity = .on   // any pending re-broadcast/pathLearned now fails at cleanup
}

/// The discriminator vs packetHash: same destination + same random_hash but DIFFERENT appData →
/// different packetHash, same blob. The second is dropped by blob-dedup (packetHash-dedup would
/// have let it through), so no second re-broadcast.
@Test @MainActor func forgeReplayWithMutatedAppDataIsDropped() async {
    let id = Identity()
    let prefix = Data(repeating: 0x7A, count: 5)
    let (first, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                               hops: 2, emitted: 1000, appData: Data("aaa".utf8),
                                               randomPrefix: prefix)
    let (forged, _)       = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                               hops: 2, emitted: 1000, appData: Data("bbb".utf8),
                                               randomPrefix: prefix)
    #expect(first != forged) // different bytes (different appData) → different packetHash
    let store = await makeRelayStore(Identity())
    await store.send(.received(InterfaceID("i0"), first))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast
    // Same blob → dropped despite different packetHash: no re-broadcast.
    await store.send(.received(InterfaceID("i0"), forged))
    store.exhaustivity = .on
}

/// The propagation change vs 4b-1: a fresh (new-blob) announce that does NOT improve the path is
/// still re-broadcast in relay mode. Under 4b-1 this produced `.none` (no re-broadcast).
@Test @MainActor func nonImprovingFreshAnnounceIsStillRebroadcast() async {
    let id = Identity()
    // First: newer emission → adopted.
    let (newer, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                               hops: 2, emitted: 2000,
                                               randomPrefix: Data(repeating: 0x01, count: 5))
    // Second: fresh blob but OLDER emission → shouldReplace false (path NOT updated).
    let (older, _)        = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                               hops: 2, emitted: 1000,
                                               randomPrefix: Data(repeating: 0x02, count: 5))
    let store = await makeRelayStore(Identity())
    await store.send(.received(InterfaceID("i0"), newer))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast for newer
    // Older fresh announce: no pathLearned, but IS re-broadcast.
    let rebroadcast = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i0"), older))
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { rebroadcast.setValue(d); return true }
        return false
    }
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast for older
    #expect(rebroadcast.value != nil)                       // re-broadcast happened
    #expect(store.state.learned[destHash]?.announceEmitted == 2000) // path NOT downgraded
}

/// The per-destination blob ring is bounded to `announceBlobRingSize` (64): after 65 distinct
/// blobs for one destination, the oldest (#0) is evicted and the newest (#64) retained. Asserted
/// on state (non-relay store) to avoid coupling to the re-broadcast action queue.
@Test @MainActor func blobRingEvictsOldestAfterCapacity() async {
    let id = Identity()
    let app = "app", aspects = ["svc"]
    let destHash = Destination.hash(identityHash: id.hash, appName: app, aspects: aspects)
    func announceRaw(_ i: Int) -> Data {
        makeAnnouncePacket(identity: id, appName: app, aspects: aspects, hops: 2, emitted: 1000,
                           randomPrefix: Data([UInt8(i), 0, 0, 0, 0])).0
    }
    func blob(_ i: Int) -> Data {
        Announce.randomHash(now: 1000, randomPrefix: Data([UInt8(i), 0, 0, 0, 0]))
    }
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    // 65 distinct blobs (#0...#64) for one destination; capacity 64 evicts the oldest (#0).
    for i in 0...64 { await store.send(.received(InterfaceID("i"), announceRaw(i))) }
    #expect(store.state.announceBlobs[destHash]?.contains(blob(0)) == false)   // #0 evicted
    #expect(store.state.announceBlobs[destHash]?.contains(blob(64)) == true)   // #64 retained
}

/// Regression: a duplicate .data packet to a local destination is still deduped by packetHash
/// (announces leaving the shared guard must not disturb non-announce dedup).
@Test @MainActor func duplicateDataStillDedupedByPacketHash() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: Identity())!
    let plaintext = Data("hello".utf8)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    let ciphertext = dest.encrypt(plaintext)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: ciphertext)
    let raw = try! packet.packed()
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i"))))
    // Duplicate → deduped by packetHash: no second delivery.
    await store.send(.received(InterfaceID("i"), raw))
    store.exhaustivity = .on
}

/// Regression: an announce for one of our own local destinations is ignored — not blob-tracked,
/// not re-broadcast.
@Test @MainActor func ownDestinationAnnounceIsIgnored() async {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: id)!
    let (raw, _) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                      hops: 2, emitted: 1000)
    let store = await makeRelayStore(Identity())
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    await store.send(.received(InterfaceID("i0"), raw))
    #expect(store.state.announceBlobs[dest.hash] == nil) // not blob-tracked
    store.exhaustivity = .on                             // no re-broadcast/pathLearned
}

// MARK: - 4b-3b-1 jittered delayed re-broadcast

/// A simulated wall clock that tracks a `TestClock`, so `clock.advance(by:)` remains the single
/// time control in relay tests. C3 pacing compares `date.now` against a per-interface
/// `allowedAt`; with the default frozen epoch-0 `transportDate`, every announce after the first
/// would queue forever. `TestClock.Instant.offset` is fileprivate, so elapsed time is recovered
/// via the public `Instant()` (offset .zero) + `duration(to:)`.
private func clockTrackingDate(_ clock: TestClock<Duration>) -> DateGenerator {
    DateGenerator {
        let elapsed = TestClock<Duration>.Instant().duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
        return Date(timeIntervalSince1970: seconds)
    }
}

/// A relay with two interfaces and a controllable clock/jitter.
/// Uses TCP-profile interfaces (10 Mbps) so the announce pacing window (~0.0001 s) is far
/// shorter than any jitter or retry advance in the existing relay-lifecycle tests, keeping
/// those tests focused on jitter/retry/cancellation behaviour rather than pacing.
@MainActor
private func makeTimedRelayStore(_ relay: Identity, _ clock: TestClock<Duration>, jitterByte: UInt8)
    async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = clockTrackingDate(clock)
        $0.continuousClock = clock
        $0.randomBytes = RandomBytesGenerator { _ in Data([jitterByte]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), .tcp))
    await store.send(.interfaceConnected(InterfaceID("i1"), .tcp))
    await store.send(.setTransportIdentity(relay))
    return store
}

/// A fresh announce learns the path immediately but re-broadcasts only after the jitter elapses,
/// to every interface except the arrival one, with the 4b-1 HEADER_2 bytes.
@Test @MainActor func freshAnnounceRebroadcastIsDeferredUntilJitterElapses() async {
    let relay = Identity()
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(relay, clock, jitterByte: 128)   // 128/256 * 0.5 = 0.25s
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    // Path learned + held, but NOT yet re-broadcast.
    #expect(store.state.learned[destHash] != nil)
    #expect(store.state.announceTable[destHash] != nil)
    await clock.advance(by: .seconds(0.24))
    #expect(store.state.announceTable[destHash] != nil)   // still holding, just before deadline
    await clock.advance(by: .seconds(0.01))               // reach 0.25s → fire send #1
    let out = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(i, d)) = action { out.setValue((i, d)); return true }
        return false
    }
    #expect(out.value?.0 == InterfaceID("i1"))            // to the OTHER interface only
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)  // retained for retry
    let rb = Packet(raw: out.value!.1)!
    #expect(rb.headerType == .header2)
    #expect(rb.transportId == relay.hash)
    #expect(Int(rb.hops) == 3)
    await clock.advance(by: .seconds(5.5))                // grace(5) + window(0.5) fixed → fire send #2
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] == nil)   // lifecycle complete at the cap
}

/// The maximum jitter byte still yields a delay strictly inside the window (< PATHFINDER_RW).
@Test @MainActor func maxJitterByteStaysWithinWindow() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 255)  // 255/256*0.5 ≈ 0.498s
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.49))
    #expect(store.state.announceTable[destHash] != nil)   // not yet (~0.498s)
    await clock.advance(by: .seconds(0.01))               // 0.50s > 0.498 → fired send #1
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)  // retained for retry
    await clock.advance(by: .seconds(5.5))               // grace(5) + window(0.5) fixed → fire send #2
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] == nil)   // lifecycle complete at the cap
}

/// A second fresh announce for the same destination within the window supersedes the first: the
/// single re-broadcast carries the newer announce's payload.
@Test @MainActor func secondFreshAnnounceSupersedesPendingRebroadcast() async {
    let id = Identity()
    let clock = TestClock()
    let (a1, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"], hops: 2,
                                            emitted: 1000, appData: Data("AAA".utf8),
                                            randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, _)        = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"], hops: 2,
                                            emitted: 2000, appData: Data("BBB".utf8),
                                            randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeTimedRelayStore(id, clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.send(.received(InterfaceID("i0"), a2))    // newer → replaces the held entry, re-arms
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    let out = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { out.setValue(d); return true }
        return false
    }
    #expect(Packet(raw: out.value!)!.payload == Packet(raw: a2)!.payload)   // newer superseded
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)         // retained for retry
    await clock.advance(by: .seconds(5.5))                // grace(5) + window(0.5) fixed → retry
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] == nil)   // lifecycle complete at the cap
}

/// A non-relay node never holds or re-broadcasts an announce.
@Test @MainActor func nonRelayNodeDoesNotScheduleRebroadcast() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    // No setTransportIdentity → leaf.
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable.isEmpty)            // nothing held
}

/// A relay with only one interface has nowhere to re-broadcast, so it schedules nothing.
@Test @MainActor func singleInterfaceRelayDoesNotSchedule() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("only")))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.received(InterfaceID("only"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash] == nil)  // no other interface → not held
}

// MARK: - C2 mode-gated relay

@MainActor
private func makeModedRelayStore(_ relay: Identity, _ clock: TestClock<Duration>,
                                 interfaces: [(InterfaceID, InterfaceProfile)],
                                 jitterByte: UInt8 = 128)
    async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = clockTrackingDate(clock)
        $0.continuousClock = clock
        $0.randomBytes = RandomBytesGenerator { _ in Data([jitterByte]) }
    }
    store.exhaustivity = .off
    for (id, profile) in interfaces {
        await store.send(.interfaceConnected(id, profile))
    }
    await store.send(.setTransportIdentity(relay))
    return store
}

private let apProfile       = InterfaceProfile(name: "ap",    bitrate: 62_500, mode: .accessPoint)
private let roamingProfile  = InterfaceProfile(name: "roam",  bitrate: 62_500, mode: .roaming)
private let boundaryProfile = InterfaceProfile(name: "bound", bitrate: 62_500, mode: .boundary)

/// An access-point interface is excluded from announce relay while a full interface still
/// receives it (RNS: AP never retransmits announces from the network).
@Test @MainActor func accessPointInterfaceIsExcludedFromAnnounceRelay() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),        // arrival, mode .full
        (InterfaceID("iAP"),   apProfile),
        (InterfaceID("iFull"), .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))                 // jittered send #1
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))                  // capped retry (send #2, lifecycle ends)
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])           // iAP excluded both rounds
    #expect(store.state.announceTable[destHash] == nil)     // lifecycle complete, no timer in flight
    store.exhaustivity = .on   // teardown now fails on any skipped transmit (e.g. one to iAP)
}

/// A roaming interface does not re-advertise an announce that arrived from another roaming
/// interface; a full interface alongside it still relays.
@Test @MainActor func roamingDoesNotRelayAnnouncesArrivingFromRoaming() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    roamingProfile),  // arrival is ROAMING
        (InterfaceID("iRoam"), roamingProfile),
        (InterfaceID("iFull"), .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])
    #expect(store.state.announceTable[destHash] == nil)
    store.exhaustivity = .on
}

/// A roaming interface also does not re-advertise announces arriving from a BOUNDARY interface.
@Test @MainActor func roamingDoesNotRelayAnnouncesArrivingFromBoundary() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    boundaryProfile), // arrival is BOUNDARY
        (InterfaceID("iRoam"), roamingProfile),
        (InterfaceID("iFull"), .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])
    #expect(store.state.announceTable[destHash] == nil)
    store.exhaustivity = .on
}

/// A boundary interface does not re-advertise announces arriving from a ROAMING interface —
/// and the full interface alongside proves full-out DOES relay from a roaming arrival.
@Test @MainActor func boundaryDoesNotRelayAnnouncesArrivingFromRoaming() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),     roamingProfile), // arrival is ROAMING
        (InterfaceID("iBound"), boundaryProfile),
        (InterfaceID("iFull"),  .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])
    #expect(store.state.announceTable[destHash] == nil)
    store.exhaustivity = .on
}

/// A relay whose only other interface cannot relay (access point) schedules nothing — the
/// scheduling gate, not just the fan-out, consults eligibility. Modeled on
/// singleInterfaceRelayDoesNotSchedule.
@Test @MainActor func relayWithOnlyIneligibleTargetsDoesNotSchedule() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), .default))
    await store.send(.interfaceConnected(InterfaceID("iAP"), apProfile))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash] == nil)   // nowhere eligible → not held
}

/// LOCALLY-ORIGINATED announces are ungated: an access point "originates only", so its own
/// announce still goes out every interface including AP-mode ones. Modeled on
/// announceFansOutToAllInterfaces.
@Test @MainActor func locallyOriginatedAnnounceStillFansOutToAccessPointInterfaces() async {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    store.exhaustivity = .off
    let dest = Destination(kind: .single, direction: .in, appName: "app",
                           aspects: ["s"], identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.interfaceConnected(InterfaceID("iAP"), apProfile))
    await store.send(.interfaceConnected(InterfaceID("iFull"), .default))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iAP"), InterfaceID("iFull")])   // BOTH — no gate here
}

/// The jitter formula maps a random byte to `byte/256` of the window, always within `[0, window)`.
/// Pins the exact delay value directly (the clock/async tests can only observe that *a* delay
/// elapsed, not the precise fraction).
@Test func announceJitterMapsByteToWindowFraction() {
    #expect(Transport.announceJitter(0) == 0.0)
    #expect(Transport.announceJitter(128) == 0.25)                                  // 128/256 * 0.5
    #expect(Transport.announceJitter(255) == Double(255) / 256.0 * 0.5)
    #expect(Transport.announceJitter(255) < Transport.announceRebroadcastWindow)    // strictly inside
}

/// The complete mode-gating table from RNS Transport.py:1224-1270. The blocked set is
/// enumerated as data; every combination not listed must relay. nil arrival = the arrival
/// interface disconnected mid-window — permissive by decision (C2 spec).
@Test func mayRelayAnnounceMatchesReferenceTable() {
    let blocked: [(InterfaceMode, InterfaceMode?)] = [
        // accessPoint out: never relays, regardless of arrival (incl. disconnected).
        (.accessPoint, nil), (.accessPoint, .full), (.accessPoint, .pointToPoint),
        (.accessPoint, .accessPoint), (.accessPoint, .roaming), (.accessPoint, .boundary),
        (.accessPoint, .gateway), (.accessPoint, .interfaceInternal),
        // roaming out: no re-advertising what came from roaming/boundary peers.
        (.roaming, .roaming), (.roaming, .boundary),
        // boundary out: no re-advertising what came from roaming peers.
        (.boundary, .roaming),
    ]
    let all: [InterfaceMode] = [.full, .pointToPoint, .accessPoint, .roaming,
                                .boundary, .gateway, .interfaceInternal]
    let arrivals: [InterfaceMode?] = all.map { $0 } + [nil]
    for out in all {
        for arrival in arrivals {
            let expected = !blocked.contains { $0.0 == out && $0.1 == arrival }
            #expect(Transport.mayRelayAnnounce(to: out, arrivalMode: arrival) == expected,
                    "out=\(out) arrival=\(String(describing: arrival))")
        }
    }
}

/// Pacing wait = transmit-time / announce_cap (RNS Transport.py:1282-1285). Values are
/// hand-derived from the reference formula: a 150-byte announce is 1200 bits; at BLE's
/// 80 kbps that is 0.015 s of air time, and at a 2% cap the interface must then stay quiet
/// for 0.015 / 0.02 = 0.75 s. The same announce on TCP's 10 Mbps costs 0.006 s — the 125×
/// spread that makes pacing matter on a slow radio and vanish on a socket.
/// 0.75, 1.5 and 0.375 are dyadic (3/4, 3/2, 3/8) so they are exactly representable in
/// binary64 and stay exact `==` oracles. 0.006 and 0.015 are not dyadic; they compare within
/// a tolerance so the assertion pins the reference formula's VALUE rather than one particular
/// rounding path — an algebraically identical rewrite such as bits / (bitrate * cap) would
/// otherwise trip them for a rounding reason instead of a correctness one.
@Test func announcePacingWaitMatchesReferenceFormula() {
    #expect(Transport.announcePacingWait(byteCount: 150, bitrate: 80_000, announceCap: 0.02)
            == 0.75)
    #expect(abs(Transport.announcePacingWait(byteCount: 150, bitrate: 10_000_000,
                                             announceCap: 0.02) - 0.006) < 1e-12)
    // Doubling the payload doubles the wait; doubling the cap halves it.
    #expect(Transport.announcePacingWait(byteCount: 300, bitrate: 80_000, announceCap: 0.02)
            == 1.5)
    #expect(Transport.announcePacingWait(byteCount: 150, bitrate: 80_000, announceCap: 0.04)
            == 0.375)
    // A full-rate cap (1.0) still yields exactly the air time.
    #expect(abs(Transport.announcePacingWait(byteCount: 150, bitrate: 80_000,
                                             announceCap: 1.0) - 0.015) < 1e-12)
}

/// Queue bounds are the reference constants (RNS Transport.py MAX_QUEUED_ANNOUNCES /
/// QUEUED_ANNOUNCE_LIFE).
@Test func announceQueueBoundsMatchReference() {
    #expect(Transport.announceQueueLimit == 16384)
    #expect(Transport.queuedAnnounceLife == 86_400)
}

// MARK: - C3 bitrate-paced announce queueing

/// A slow interface relays the first announce immediately, then QUEUES the next one that
/// arrives inside its pacing window rather than transmitting it.
@Test @MainActor func secondAnnounceInsidePacingWindowIsQueuedNotSent() async {
    let clock = TestClock()
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)   // 1000 B/s
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),      // arrival
        (InterfaceID("iSlow"), slow),
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))                 // jitter → send #1 goes out
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceQueues[InterfaceID("iSlow")] == nil)   // nothing queued yet
    #expect(store.state.announceAllowedAt[InterfaceID("iSlow")] != nil)

    // A second announce arrives well inside the pacing window (183 B at 8 kbps / 0.02 ≈ 9 s).
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))                 // its jitter elapses
    // TCA .off mode: state from effect-dispatched actions is only visible after skipReceivedActions
    // drains the internal announceRetransmitDue action from the received-actions queue.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.announceQueues[InterfaceID("iSlow")]?.count == 1)  // QUEUED, not sent
    await store.send(.stopMaintenance)                      // quiesce
}

/// A queued announce is transmitted when the pacing window expires — the drain timer fires
/// on its own, without another announce arriving.
@Test @MainActor func queuedAnnounceIsDrainedWhenPacingWindowExpires() async {
    let clock = TestClock()
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),
        (InterfaceID("iSlow"), slow),
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    // TCA .off mode: drain internal announceRetransmitDue to make queue visible in store.state.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.announceQueues[InterfaceID("iSlow")]?.count == 1)

    // Stop relay mode so lifecycle retries (which would also queue) are cancelled before
    // advancing past the pacing window — leaving exactly the one drain timer in-flight.
    // The drain handler is independent of relay identity and will still fire.
    await store.send(.setTransportIdentity(nil))

    // Advance past the pacing window: the drain fires and emits the held announce.
    let drained = LockIsolated<Data?>(nil)
    await clock.advance(by: .seconds(12))
    await store.receive { action in
        if case let .delegate(.transmit(i, d)) = action, i == InterfaceID("iSlow") {
            drained.setValue(d); return true
        }
        return false
    }
    #expect(drained.value != nil)
    #expect(store.state.announceQueues[InterfaceID("iSlow")] == nil)   // queue emptied
    await store.send(.stopMaintenance)
}

/// A fast interface never queues: its pacing window is far shorter than the retransmit grace,
/// so back-to-back announces both go out immediately.
@Test @MainActor func fastInterfaceNeverQueuesAnnounces() async {
    let clock = TestClock()
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),
        (InterfaceID("iFast"), .tcp),          // 10 Mbps → ~0.0001 s window
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceQueues[InterfaceID("iFast")] == nil)   // never queued
    await store.send(.stopMaintenance)
}

/// Disconnecting an interface drops its pacing state and queued announces — no residue, and
/// no drain timer left running for an interface that is gone.
@Test @MainActor func disconnectClearsPacingStateAndQueue() async {
    let clock = TestClock()
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),
        (InterfaceID("iSlow"), slow),
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    // TCA .off mode: drain internal announceRetransmitDue to make queue visible in store.state.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.announceQueues[InterfaceID("iSlow")]?.count == 1)

    await store.send(.interfaceDisconnected(InterfaceID("iSlow")))
    #expect(store.state.announceQueues[InterfaceID("iSlow")] == nil)
    #expect(store.state.announceAllowedAt[InterfaceID("iSlow")] == nil)
    await store.send(.stopMaintenance)
}

// MARK: - 4b-3b-2 announce re-broadcast retries + grace

/// A fresh announce is re-broadcast twice (initial after jitter, one retry after grace+jitter),
/// with identical bytes, then the lifecycle completes and no third send occurs.
@Test @MainActor func announceRebroadcastRetriesTwiceThenStops() async {
    let relay = Identity()
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(relay, clock, jitterByte: 128)   // jitter 0.25; retry 5.5 fixed
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 0)

    await clock.advance(by: .seconds(0.25))                    // fire send #1
    let first = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { first.setValue(d); return true }
        return false
    }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)   // retained, one send done

    await clock.advance(by: .seconds(5.5))                     // grace(5) + window(0.5) fixed → send #2
    let second = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { second.setValue(d); return true }
        return false
    }
    #expect(second.value == first.value)                       // identical held bytes
    #expect(store.state.announceTable[destHash] == nil)        // lifecycle complete at the cap

    await clock.advance(by: .seconds(5.5))                     // no third send scheduled
    #expect(store.state.announceTable[destHash] == nil)
}

/// A superseding fresh announce during the grace window resets the retry lifecycle: the pending
/// retry is cancelled and a new single-then-retry chain starts for the newer announce.
@Test @MainActor func supersedingAnnounceResetsRetryLifecycle() async {
    let id = Identity()
    let clock = TestClock()
    let (a1, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"], hops: 2,
                                            emitted: 1000, appData: Data("AAA".utf8),
                                            randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, _)        = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"], hops: 2,
                                            emitted: 2000, appData: Data("BBB".utf8),
                                            randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeTimedRelayStore(id, clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))                    // a1 send #1
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)

    // Supersede during the grace window (before a1's retry at +5.5).
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 0)          // reset by supersede

    await clock.advance(by: .seconds(0.25))                    // a2 send #1
    let out = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { out.setValue(d); return true }
        return false
    }
    #expect(Packet(raw: out.value!)!.payload == Packet(raw: a2)!.payload)    // newer announce won
    await clock.advance(by: .seconds(5.5))                     // a2 retry
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] == nil)
}

// MARK: - 4b-3b-3 collaborative announce suppression

/// Build a HEADER_2 "re-broadcast" of a HEADER_1 announce `originalRaw`, with the SAME payload
/// (→ same random_hash → same blob, i.e. a replay) at a chosen hop count and a peer transport_id.
private func peerRebroadcast(of originalRaw: Data, hops: UInt8) -> Data {
    let orig = Packet(raw: originalRaw)!
    let p = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                   destinationType: orig.destinationType, context: orig.context,
                   contextFlag: orig.contextFlag, hops: hops,
                   destinationHash: orig.destinationHash,
                   transportId: Data(repeating: 0x99, count: 16), payload: orig.payload)
    return try! p.packed()
}

/// After our first send (retry pending), two peer re-broadcasts (hops == rebroadcastHops) reach the
/// cap and cancel the pending retry.
@Test @MainActor func peerRebroadcastsCancelPendingRetryAtCap() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)   // arrival 2 → rebroadcastHops 3
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))              // send #1 → rebroadcasts=1, retry pending
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)
    #expect(store.state.announceTable[destHash]?.rebroadcastHops == 3)
    // Peer re-broadcast #1: counts, no cancel.
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 1)
    #expect(store.state.announceTable[destHash] != nil)
    // Peer re-broadcast #2: reaches the cap (2) → cancel the retry.
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    #expect(store.state.announceTable[destHash] == nil)
    // Retry was cancelled: advancing past the grace fires nothing.
    await clock.advance(by: .seconds(5.5))
    #expect(store.state.announceTable[destHash] == nil)
}

/// A downstream re-broadcast (hops == rebroadcastHops + 1) cancels the pending retry immediately.
@Test @MainActor func downstreamRebroadcastCancelsPendingRetry() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    // hops == rebroadcastHops + 1 == 4 → cancel.
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 4)))
    #expect(store.state.announceTable[destHash] == nil)
    await clock.advance(by: .seconds(5.5))
    #expect(store.state.announceTable[destHash] == nil)
}

/// Peer re-broadcasts BEFORE the first send (initial jitter window, rebroadcasts==0) count but do
/// NOT cancel — the initial send is never suppressed.
@Test @MainActor func peerRebroadcastsBeforeFirstSendDoNotCancel() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 0)   // holding the initial send
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 2)
    #expect(store.state.announceTable[destHash] != nil)              // NOT cancelled (rebroadcasts==0)
    // Initial send still fires; drain both sends of the (un-suppressed) lifecycle.
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // send #1
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)
    await clock.advance(by: .seconds(5.5))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry (send #2)
}

/// A same-blob HEADER_2 replay whose hops match neither rebroadcastHops nor +1 leaves the pending
/// retry untouched.
@Test @MainActor func nonMatchingHopsReplayDoesNotSuppress() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 7)))   // neither 3 nor 4
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 0)
    await clock.advance(by: .seconds(5.5))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry still fires
}

/// A HEADER_1 replay (transport_id == nil) is not a relay re-broadcast → no suppression, no count.
@Test @MainActor func header1ReplayDoesNotSuppress() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    // Same-blob HEADER_1 replay at hops == rebroadcastHops: transportId nil → not counted.
    let orig = Packet(raw: raw)!
    let h1 = try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                         destinationType: orig.destinationType, context: orig.context,
                         contextFlag: orig.contextFlag, hops: 3,
                         destinationHash: orig.destinationHash, transportId: nil,
                         payload: orig.payload).packed()
    await store.send(.received(InterfaceID("i0"), h1))
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 0)
    #expect(store.state.announceTable[destHash] != nil)
    await clock.advance(by: .seconds(5.5))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry still fires
}

// MARK: - 4b-3c-1 maintenance tick + expiry

/// An aged-out learned path (and its random-blob ring) is swept once now − learnedAt > pathExpiry;
/// a not-yet-expired path survives an earlier tick.
/// (C1) Also covers the mode-fallback branch: i0 is never connected, so the sweep finds no
/// profile and must use the 7-day default rather than expiring early.
@Test @MainActor func expiredPathAndBlobsAreSweptByMaintenanceTick() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash] != nil)
    #expect(store.state.announceBlobs[destHash] != nil)
    #expect(store.state.announceCache[destHash] != nil)

    await store.send(.startMaintenance)
    // Not yet expired: a tick within the window sweeps nothing.
    now.setValue(Date(timeIntervalSince1970: 100))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    // Past the expiry: the next tick sweeps the path and its blob ring.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    #expect(store.state.announceBlobs[destHash] == nil)
    #expect(store.state.announceCache[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// A path learned on an ACCESS-POINT interface expires after 1 day (RNS AP_PATH_TIME,
/// Transport.py:787-792), not the 7-day default.
@Test @MainActor func accessPointPathExpiresAfterOneDay() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let ap = InterfaceProfile(name: "ap", bitrate: 62_500, mode: .accessPoint)
    await store.send(.interfaceConnected(InterfaceID("i0"), ap))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    await store.send(.startMaintenance)
    // Just inside the AP window: survives.
    now.setValue(Date(timeIntervalSince1970: Transport.apPathExpiry - 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    // Just past it: swept — days before the 7-day default would fire.
    now.setValue(Date(timeIntervalSince1970: Transport.apPathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    #expect(store.state.announceBlobs[destHash] == nil)   // blob GC piggybacks (spec)
    #expect(store.state.announceCache[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// A path learned on a ROAMING interface expires after 6 hours (RNS ROAMING_PATH_TIME).
@Test @MainActor func roamingPathExpiresAfterSixHours() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let roaming = InterfaceProfile(name: "cell", bitrate: 80_000, mode: .roaming)
    await store.send(.interfaceConnected(InterfaceID("i0"), roaming))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry - 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    now.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// A path on a FULL-mode interface is NOT shortened: it survives past both the AP and roaming
/// windows and holds to the 7-day default. Proves the sweep branches per-path rather than
/// globally shortening.
@Test @MainActor func fullModePathSurvivesShortWindows() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), .default))   // mode .full
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.apPathExpiry + 1))       // past AP window
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))         // past 7 days
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// CHARACTERIZATION TEST for a behaviour RULED INTENDED by the 2026-08-13 destructive-transition
/// sweep (see `docs/superpowers/2026-08-13-destructive-transition-sweep.md`, the ruling under §4's
/// row 34). It is here because the ruling has no F-number, and an intended behaviour with no test
/// is indistinguishable from an unnoticed one.
///
/// THE BEHAVIOUR: a genuine newer announce arriving on a `.roaming` interface re-homes a path
/// previously learned on a `.full` one — `Transport.shouldReplace` compares only `announceEmitted`
/// and `hops`, so it is MODE-BLIND — and the maintenance sweep reads
/// `pathExpiry(forMode: interfaces[entry.interfaceID]?.mode)` at GC time. Net effect: the path's
/// lifetime drops from the 7-day default to the 6-hour roaming window. Inbound data has moved a GC
/// earlier, which is why the sweep had to retract a universal that said it could not.
///
/// WHY IT IS INTENDED, so that a future edit confronts the reasoning rather than the symptom: after
/// the replacement the entry genuinely IS a roaming path. `Transport.send` transmits on
/// `entry.interfaceID`, which now names the roaming interface, so the route really does run over it,
/// and classifying it by the mode it actually rides is the entire purpose of `pathExpiry(forMode:)`.
/// Nothing is truncated mid-life either: the replacement also resets `learnedAt`, so the entry gets
/// a FULL roaming lifetime measured from the moment it became a roaming path.
///
/// WHAT THIS PINS THAT THE NEIGHBOURING TESTS DO NOT. `roamingPathExpiresAfterSixHours` and
/// `fullModePathSurvivesShortWindows` each connect ONE interface and never re-class anything, so
/// adding a mode comparison to `shouldReplace` breaks neither. It breaks the first assertion here.
/// The control half — the same newer announce arriving on the FULL interface — is what keeps the
/// re-class load-bearing rather than passing under a blanket "everything expires at 6h".
@Test @MainActor func newerAnnounceOnRoamingInterfaceReClassesAFullLearnedPathToTheRoamingLifetime() async {
    // One identity, so both announces name the SAME destination. The convenience overload mints a
    // fresh Identity per call and would give two different destinations.
    let peer = Identity()
    let (first, destHash) = makeAnnouncePacket(identity: peer, appName: "app", aspects: ["svc"],
                                               hops: 2, emitted: 1000)
    // Strictly newer `emitted` → wins `shouldReplace`, and also yields a different announce blob,
    // so it is not dropped as a replay.
    let (newer, newerDest) = makeAnnouncePacket(identity: peer, appName: "app", aspects: ["svc"],
                                                hops: 2, emitted: 2000)
    #expect(newerDest == destHash)

    let fullIf = InterfaceID("i-full"), roamIf = InterfaceID("i-roam")
    let roaming = InterfaceProfile(name: "cell", bitrate: 80_000, mode: .roaming)

    // --- the re-class: newer announce arrives on the ROAMING interface ---
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(fullIf, .default))          // mode .full
    await store.send(.interfaceConnected(roamIf, roaming))
    await store.send(.received(fullIf, first))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash]?.interfaceID == fullIf)

    await store.send(.received(roamIf, newer))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash]?.interfaceID == roamIf)    // mode-blind replacement

    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry - 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)                    // full roaming lifetime, not truncated
    now.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    // Under the ORIGINAL full binding this entry had ~7 days left.
    #expect(store.state.learned[destHash] == nil)
    await store.send(.stopMaintenance)

    // --- control: the same newer announce on the FULL interface does NOT shorten anything ---
    let clock2 = TestClock()
    let now2 = LockIsolated(Date(timeIntervalSince1970: 0))
    let control = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock2
        $0.transportDate = DateGenerator { now2.value }
    }
    control.exhaustivity = .off
    await control.send(.interfaceConnected(fullIf, .default))
    await control.send(.interfaceConnected(roamIf, roaming))
    await control.send(.received(fullIf, first))
    await control.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await control.send(.received(fullIf, newer))
    await control.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(control.state.learned[destHash]?.interfaceID == fullIf)

    await control.send(.startMaintenance)
    now2.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry + 1))
    await clock2.advance(by: .seconds(Transport.maintenanceTickInterval))
    await control.receive(.maintenanceTick)
    #expect(control.state.learned[destHash] != nil)                  // still on the 7-day window
    await control.send(.stopMaintenance)
}

/// A stale relay linkTable entry is swept; an entry refreshed by a link-packet forward survives.
@Test @MainActor func staleLinkEntrySweptButRefreshedSurvives() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let relay = Identity(), remote = Identity()
    let outIf = InterfaceID("i-out")
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["d"], hops: 1, emitted: 2000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
        $0.randomBytes = RandomBytesGenerator { _ in Data([0]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(outIf))          // one interface → announce won't re-broadcast
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(outIf, announceRaw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    // Create a linkTable entry (refreshedAt = 0) via a HEADER_2 LINKREQUEST arriving on "in".
    let payload = Data(repeating: 0x11, count: 64) + Data([0, 0, 0])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID] != nil)

    // Validate the entry by forwarding an LRPROOF at t = 5 (before the entry's proofDeadline).
    now.setValue(Date(timeIntervalSince1970: 5))
    let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                       destinationType: .link, context: .linkRequestProof, contextFlag: false, hops: 0,
                       destinationHash: linkID, transportId: nil, payload: Data(repeating: 0x1, count: 96))
    await store.send(.received(InterfaceID("in"), try! proof.packed()))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID]?.validated == true)

    // Refresh the entry by forwarding a link packet arriving on rcvdIf ("in") at t = 10.
    now.setValue(Date(timeIntervalSince1970: 10))
    let linkPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: linkID, transportId: nil, payload: Data([9]))
    await store.send(.received(InterfaceID("in"), try! linkPacket.packed()))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID]?.refreshedAt == Date(timeIntervalSince1970: 10))

    await store.send(.startMaintenance)
    // now = expiry+1 (901): age since CREATION(0) = 901 > 900, but age since REFRESH(10) = 891 < 900.
    // So the entry survives ONLY because it was refreshed — the refresh discriminator.
    now.setValue(Date(timeIntervalSince1970: Transport.linkTableExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.linkTable[linkID] != nil)          // survived: refreshed at 10
    // now = 10 + expiry + 1 (911): age since refresh(10) = 901 > 900 → swept.
    now.setValue(Date(timeIntervalSince1970: 10 + Transport.linkTableExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.linkTable[linkID] == nil)
    await store.send(.stopMaintenance)
}

/// stopMaintenance cancels the tick — no further sweeps fire.
@Test @MainActor func stopMaintenanceCancelsTheTick() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.startMaintenance)
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)                  // one tick fired
    await store.send(.stopMaintenance)
    store.exhaustivity = .on                               // any further emitted action now fails at cleanup
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval * 3))  // no tick → cancelled
}

/// Stopping relaying cancels a pending announce re-broadcast retry and clears the announce table.
@Test @MainActor func relayStopCancelsPendingRebroadcastAndClearsAnnounceTable() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = .constant(Date(timeIntervalSince1970: 0))
        $0.randomBytes = RandomBytesGenerator { _ in Data([128]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))                     // send #1 → retry pending
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] != nil)
    // Stop relaying → cancel the pending retry + clear the table.
    await store.send(.setTransportIdentity(nil))
    // The announce table is cleared, so the destination is no longer held for re-broadcast. (The
    // handler also cancels the pending retry timer as hygiene; that cancel has no *observable*
    // effect — the cleared table already makes any fired retry a no-op — so it is not separately
    // asserted here. `.off` tolerates the sleeping retry effect at deinit.)
    #expect(store.state.announceTable.isEmpty)
}

/// Stopping relaying clears the link table (relay reverse-routing is meaningless without relay mode).
@Test @MainActor func relayStopClearsLinkTable() async {
    let (store, relay, destHash, _) = await relayStoreKnowingDestDirectly()
    let payload = Data(repeating: 0x11, count: 64) + Data([0, 0, 0])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID] != nil)
    await store.send(.setTransportIdentity(nil))
    #expect(store.state.linkTable.isEmpty)
}

// MARK: - #4c-1 path requests

/// A helper to build a raw PATH_REQUEST for a destination (non-relay: destHash ‖ tag).
private func makePathRequest(for destHash: Data, tag: Data = Data(repeating: 0x5A, count: 16)) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash + tag)
    return try! packet.packed()
}

/// requestPath broadcasts a DATA PATH_REQUEST to the control dest with destHash ‖ tag payload.
@Test @MainActor func requestPathBuildsBroadcastPathRequest() async {
    let destHash = Data(repeating: 0x22, count: 16)
    let tag = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.randomBytes = RandomBytesGenerator { _ in tag }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.requestPath(destinationHash: destHash))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let p = Packet(raw: captured.value!)!
    #expect(p.packetType == .data)
    #expect(p.transportType == .broadcast)
    #expect(p.headerType == .header1)
    #expect(p.destinationType == .plain)
    #expect(p.destinationHash == Transport.pathRequestDestinationHash)
    #expect(Data(p.payload.prefix(16)) == destHash)
    #expect(Data(p.payload.dropFirst(16)) == tag)         // non-relay → no transport_id
}

/// A relay's PATH_REQUEST includes its transport_id: destHash ‖ transportId ‖ tag.
@Test @MainActor func relayRequestPathIncludesTransportId() async {
    let relay = Identity()
    let destHash = Data(repeating: 0x22, count: 16)
    let tag = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.randomBytes = RandomBytesGenerator { _ in tag }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.requestPath(destinationHash: destHash))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let payload = Packet(raw: captured.value!)!.payload
    #expect(Data(payload.prefix(16)) == destHash)
    #expect(Data(payload.dropFirst(16).prefix(16)) == relay.hash)
    #expect(Data(payload.dropFirst(32)) == tag)
}

/// A node that OWNS the requested destination answers with a path-response announce on the arrival iface.
@Test @MainActor func localDestinationAnswersPathRequestWithPathResponse() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("in") {
            captured.setValue(raw); return true
        }
        return false
    }
    let resp = Packet(raw: captured.value!)!
    #expect(resp.packetType == .announce)
    #expect(resp.context == .pathResponse)
    #expect(resp.destinationHash == dest.hash)
    let parsed = Announce.parse(payload: resp.payload, destinationHash: resp.destinationHash,
                                contextFlagSet: resp.contextFlag)
    #expect(parsed?.identity.hash == identity.hash)
}

/// A path response must carry the destination's announced app data. Without it the response —
/// which has a NEWER timestamp than the original announce — overwrites the requester's entry
/// with nil, erasing display name / PN metadata (Destination.py:283-304).
@Test @MainActor func localPathResponseCarriesAnnouncedAppData() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["appdata"], identity: identity)!
    let appData = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off

    // Connect interface first so .announce has somewhere to transmit.
    await store.send(.interfaceConnected(InterfaceID("a"), .default))
    await store.send(.registerLocalDestination(dest))
    await store.send(.announce(destinationHash: dest.hash, appData: appData))
    // drain the announce transmit so it doesn't interfere with the path-response capture
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }

    // Send a PATH_REQUEST for our own destination.
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("a"), makePathRequest(for: dest.hash)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }

    let responsePacket = Packet(raw: captured.value!)!
    #expect(responsePacket.context == .pathResponse)
    let parsed = Announce.parse(payload: responsePacket.payload,
                                destinationHash: responsePacket.destinationHash,
                                contextFlagSet: responsePacket.contextFlag)
    #expect(parsed?.appData == appData)
}

/// An announce that OMITS app data must fall back to the sticky value rather than putting nil on
/// the wire. Reference substitutes `default_app_data` for every announce, ordinary and
/// path-response alike, because both are one function (RNS/Destination.py:289-296). Without the
/// fallback, `announce(X)` then `announce(nil)` advertises nil while path responses still carry X,
/// and the newer nil announce wins `shouldReplace` on the requester — re-opening the very erasure
/// the path-response fix closed, through a different packet type.
@Test @MainActor func announceWithoutAppDataFallsBackToTheStickyValue() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["sticky"], identity: identity)!
    let appData = Data([0xC0, 0xFF, 0xEE])
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("a"), .default))
    await store.send(.registerLocalDestination(dest))
    await store.send(.announce(destinationHash: dest.hash, appData: appData))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.localAppData[dest.hash] == appData)

    // The sticky value must survive an announce that carries none — this also pins the `if let`
    // on the write: making it unconditional would clear the entry here.
    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.localAppData[dest.hash] == appData)

    let announced = Packet(raw: captured.value!)!
    #expect(announced.packetType == .announce)
    #expect(announced.context == .none)             // an ordinary announce, not a path response
    let parsed = Announce.parse(payload: announced.payload, destinationHash: announced.destinationHash,
                                contextFlagSet: announced.contextFlag)
    #expect(parsed?.appData == appData)
}

/// Registering a destination clears its sticky app data — ReTiCA's `clear_default_app_data()`
/// (RNS/Destination.py:688-692), and the only clear path there is, since `.announce` never erases.
/// Both the announce and the path response must then advertise nothing.
@Test @MainActor func registeringADestinationClearsItsStickyAppData() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["clear"], identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("a"), .default))
    await store.send(.registerLocalDestination(dest))
    await store.send(.announce(destinationHash: dest.hash, appData: Data([0xDE, 0xAD])))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.localAppData[dest.hash] == Data([0xDE, 0xAD]))

    // Re-register: the new registration has made no claim about app data yet.
    await store.send(.registerLocalDestination(dest))
    #expect(store.state.localAppData[dest.hash] == nil)

    // The announce fallback now has nothing to fall back to...
    let announced = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { announced.setValue(raw); return true }
        return false
    }
    let announcePacket = Packet(raw: announced.value!)!
    #expect(Announce.parse(payload: announcePacket.payload,
                           destinationHash: announcePacket.destinationHash,
                           contextFlagSet: announcePacket.contextFlag)?.appData == nil)

    // ...and neither does the path response.
    let response = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("a"), makePathRequest(for: dest.hash)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { response.setValue(raw); return true }
        return false
    }
    let responsePacket = Packet(raw: response.value!)!
    #expect(responsePacket.context == .pathResponse)
    #expect(Announce.parse(payload: responsePacket.payload,
                           destinationHash: responsePacket.destinationHash,
                           contextFlagSet: responsePacket.contextFlag)?.appData == nil)
}

// MARK: - An unsendable app data must not poison the sticky value

/// App data one byte too large to fit an announce packet. `Packet.mtu` (500) minus the 19-byte
/// HEADER_1 header minus the 148-byte fixed announce payload leaves 333 bytes; 334 cannot be sent.
private let oversizeAppData = Data(repeating: 0xAB, count: 334)

/// A short blob that definitely fits, used as the "healthy" value in the poisoning tests.
private let smallAppData = Data([0xC0, 0xFF, 0xEE])

@MainActor
private func makeStickyAppDataStore(_ dest: Destination) async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("a"), .default))
    await store.send(.registerLocalDestination(dest))
    await store.send(.announce(destinationHash: dest.hash, appData: smallAppData))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    return store
}

/// An announce whose packet cannot be built must leave `localAppData` alone.
///
/// The write used to happen BEFORE `packed()`, so an oversize app data was captured even though
/// nothing went out — and because the captured value is sticky and is the fallback for every later
/// announce, the destination went permanently silent. Reference cannot reach this state: RNS
/// `Packet.pack` RAISES on MTU overflow (RNS 1.4.2 Packet.py:234-236) instead of failing silently,
/// and its `default_app_data` is written only by an explicit `set_default_app_data()`.
///
/// Anti-vacuity: the healthy announce is drained first and its sticky capture asserted, so the
/// post-condition is "unchanged from a known non-nil value", not "still nil".
@Test @MainActor func anAnnounceThatCannotBePackedLeavesTheStickyAppDataUnchanged() async {
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["poison"], identity: Identity())!
    let store = await makeStickyAppDataStore(dest)
    #expect(store.state.localAppData[dest.hash] == smallAppData)

    await store.send(.announce(destinationHash: dest.hash, appData: oversizeAppData))
    #expect(store.state.localAppData[dest.hash] == smallAppData)
}

/// The severity half: after an announce that could not be packed, the NEXT announce must still go
/// out. With the poisoned sticky value, `announce(nil)` fell back to the oversize blob and emitted
/// nothing — every subsequent announce failed, for the life of the process, with no error anywhere.
///
/// Anti-vacuity: this asserts a transmit was received AND that its announce payload carries the
/// original app data. A fix that merely stopped writing but also stopped announcing would fail the
/// `#require`, and one that announced with the wrong bytes would fail the payload check.
@Test @MainActor func anAnnounceAfterOneThatCouldNotBePackedStillTransmits() async throws {
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["poison2"], identity: Identity())!
    let store = await makeStickyAppDataStore(dest)

    await store.send(.announce(destinationHash: dest.hash, appData: oversizeAppData))

    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }

    let raw = try #require(captured.value, "the follow-up announce must still be transmitted")
    let packet = try #require(Packet(raw: raw))
    #expect(packet.packetType == .announce)
    let parsed = try #require(Announce.parse(payload: packet.payload,
                                             destinationHash: packet.destinationHash,
                                             contextFlagSet: packet.contextFlag))
    #expect(parsed.appData == smallAppData)
}

/// The second reachable consequence, verified rather than reasoned: the local path-response branch
/// replays `localAppData` through the same `try?`, so a poisoned entry left PATH REQUESTS for our
/// own destination unanswered too. Probed before the fix — the path response emitted nothing.
///
/// The request tag differs from the one used elsewhere in this file so that the `discoveryPrTags`
/// entry gate cannot swallow it as a duplicate.
@Test @MainActor func aPathResponseStillAnswersAfterAnAnnounceThatCouldNotBePacked() async throws {
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["poison3"], identity: Identity())!
    let store = await makeStickyAppDataStore(dest)

    await store.send(.announce(destinationHash: dest.hash, appData: oversizeAppData))

    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("a"),
                               makePathRequest(for: dest.hash, tag: Data(repeating: 0x77, count: 16))))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }

    let raw = try #require(captured.value, "the path request must still be answered")
    let packet = try #require(Packet(raw: raw))
    #expect(packet.context == .pathResponse)
    let parsed = try #require(Announce.parse(payload: packet.payload,
                                             destinationHash: packet.destinationHash,
                                             contextFlagSet: packet.contextFlag))
    #expect(parsed.appData == smallAppData)
}

/// A PATH_REQUEST for a destination we do not own is not answered.
@Test @MainActor func pathRequestForNonLocalDestinationIsNotAnswered() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let unknown = Data(repeating: 0x77, count: 16)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: unknown)))
    store.exhaustivity = .on          // no transmit is emitted
}

/// End-to-end: the responder's path-response announce is learned by a second (requester) Transport.
@Test @MainActor func pathResponseAnnounceIsLearnedByRequester() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    // Owner produces a path-response announce.
    let owner = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    owner.exhaustivity = .off
    await owner.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let response = LockIsolated<Data?>(nil)
    await owner.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash)))
    await owner.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { response.setValue(raw); return true }
        return false
    }
    // Requester learns the path from that announce, like any announce.
    let requester = TestStore(initialState: Transport.State()) { Transport() }
    requester.exhaustivity = .off
    await requester.send(.received(InterfaceID("up"), response.value!))
    await requester.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(requester.state.learned[dest.hash]?.identity.hash == identity.hash)
}

/// A tagless PATH_REQUEST: just the 16-byte destination hash, no tag (RNS ignores these).
private func makeTaglessPathRequest(for destHash: Data) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash)
    return try! packet.packed()
}

/// A tagless (16-byte, no tag) request to an OWNED destination is ignored (RNS Transport.py:2935).
@Test @MainActor func taglessPathRequestToOwnedDestinationIsIgnored() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    await store.send(.received(InterfaceID("in"), makeTaglessPathRequest(for: dest.hash)))
    store.exhaustivity = .on          // no transmit — the tagless request produced no answer
}

/// A duplicate tagged request is ignored (RNS discovery_pr_tags, Transport.py:2924-2934). Uses two
/// requests with the SAME (destHash ‖ tag) but DIFFERENT transport_ids, so their bytes differ and
/// seenPacketHashes does NOT dedup them — the tag gate must. The dup is sent last, then the store
/// goes exhaustive: a stray answer is an un-received delegate action caught at teardown (removing
/// the dedup guard breaks this).
@Test @MainActor func duplicateTaggedPathRequestIsIgnored() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let tag = Data(repeating: 0xA1, count: 16)
    let tid1 = Data(repeating: 0x11, count: 16)
    let tid2 = Data(repeating: 0x22, count: 16)

    // Fresh tag → answered.
    let first = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"),
                               makeRelayPathRequest(for: dest.hash, requestorTransportId: tid1, tag: tag)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { first.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: first.value!)?.context == .pathResponse)

    // Same tag, different transport_id → distinct bytes (passes seenPacketHashes) but same unique_tag
    // → tag-deduped. Flip to .on with nothing after: a stray transmit fails teardown.
    await store.send(.received(InterfaceID("in"),
                               makeRelayPathRequest(for: dest.hash, requestorTransportId: tid2, tag: tag)))
    store.exhaustivity = .on
}

/// Distinct tags are each answered — the dedup is not over-broad (it keys on destHash ‖ tag).
@Test @MainActor func distinctTagPathRequestsAreEachAnswered() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let tagA = Data(repeating: 0xA1, count: 16)
    let tagB = Data(repeating: 0xB2, count: 16)

    for tag in [tagA, tagB] {
        let captured = LockIsolated<Data?>(nil)
        await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tag)))
        await store.receive { action in
            if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
            return false
        }
        #expect(Packet(raw: captured.value!)?.context == .pathResponse)
    }
}

// MARK: - #4c-2 relay answers from cache

/// A relay's PATH_REQUEST: destHash ‖ requestor_transport_id ‖ tag.
private func makeRelayPathRequest(for destHash: Data, requestorTransportId: Data,
                                  tag: Data = Data(repeating: 0x5A, count: 16)) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash + requestorTransportId + tag)
    return try! packet.packed()
}

/// A relay that has learned a path answers a PATH_REQUEST from cache with a HEADER_2
/// pathResponse announce (our transport_id, hops = learned+1, verbatim cached payload)
/// on the arrival interface.
@Test @MainActor func relayAnswersPathRequestFromCache() async {
    let relay = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let cachedPayload = Packet(raw: announceRaw)!.payload
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    // Learn a path to destHash (HEADER_1 announce, directly heard → nextHop == destHash).
    await store.send(.received(InterfaceID("i0"), announceRaw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("i0") {
            captured.setValue(raw); return true
        }
        return false
    }
    let resp = Packet(raw: captured.value!)!
    #expect(resp.packetType == .announce)
    #expect(resp.headerType == .header2)
    #expect(resp.transportType == .transport)
    #expect(resp.context == .pathResponse)
    #expect(resp.transportId == relay.hash)
    #expect(resp.destinationHash == destHash)
    #expect(resp.hops == 3)                       // learned hops (2) + 1
    #expect(resp.payload == cachedPayload)        // verbatim → signature intact
}

/// A HEADER_1 announce that CARRIES a ratchet: the 32 ratchet bytes sit in the payload and the
/// context flag is set to say so.
private func makeRatchetAnnouncePacket(hops: UInt8, emitted: UInt64 = 1000,
                                       ratchet: Data) -> (Data, Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "relay", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "relay", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, ratchet: ratchet)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: true, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

/// The relay replays the cached announce's BYTES verbatim, so the path response must carry the
/// ORIGINAL announce's context flag — the flag is a field-layout declaration about those bytes,
/// not a statement about what we parsed out of them. A low-order ratchet is dropped at parse
/// (`learned[dest].ratchet == nil`) while its 32 bytes stay in the payload; deriving the flag from
/// parsed state emits contextFlag=false over a ratchet-carrying payload, and the receiver then
/// parses with ratchetLen=0 and misaligns the signature and app-data fields.
@Test @MainActor func relayPathResponseCarriesCachedAnnouncesContextFlag() async {
    let relay = Identity()
    // Canonical low-order X25519 point: CryptoKit constructs it but cannot agree with it, so
    // Announce.parse keeps the announce and drops the ratchet.
    let lowOrder = Data(repeating: 0x00, count: 32)
    let (announceRaw, destHash) = makeRatchetAnnouncePacket(hops: 2, ratchet: lowOrder)
    let cachedPayload = Packet(raw: announceRaw)!.payload
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(InterfaceID("i0"), announceRaw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    // Precondition: the ratchet was dropped, so parsed state disagrees with the cached bytes.
    #expect(store.state.learned[destHash]?.ratchet == nil)

    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("i0") {
            captured.setValue(raw); return true
        }
        return false
    }
    let resp = Packet(raw: captured.value!)!
    #expect(resp.payload == cachedPayload)        // verbatim bytes, ratchet included
    #expect(resp.contextFlag == true)             // ... so the flag must say the ratchet is there
    // And the response must actually re-parse: with the wrong flag the signature field is read
    // 32 bytes early and validation fails.
    #expect(Announce.parse(payload: resp.payload, destinationHash: destHash,
                           contextFlagSet: resp.contextFlag) != nil)
}

/// A non-relay (transportIdentity == nil) never answers from cache — that is the relay-only path.
@Test @MainActor func nonRelayDoesNotAnswerPathRequestFromCache() async {
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), announceRaw))     // learns + caches, but leaf mode
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    store.exhaustivity = .on                                        // no transmit
}

/// A relay with no cached path for the requested destination does not answer (bounds the
/// relay-answer to known paths; recursive re-broadcast is #4c-3).
@Test @MainActor func relayWithoutCachedPathDoesNotAnswer() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x77, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    store.exhaustivity = .on                                        // no transmit
}

/// Loop guard: a relay does not answer when the requester's transport_id equals our next hop
/// toward the destination (RNS Transport.py:2987) — but answers when it differs.
/// A HEADER_2 announce for a fresh destination relayed via `upstream` — learning it sets the path's
/// nextHop == `upstream.hash`, so a request carrying that transport_id trips the loop guard.
private func makeRelayedAnnounce(via upstream: Identity) -> (raw: Data, destHash: Data) {
    let (h1Raw, destHash) = makeAnnouncePacket(hops: 2)
    let h1 = Packet(raw: h1Raw)!
    let relayedAnnounce = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                                 destinationType: .single, context: .none, contextFlag: false, hops: 2,
                                 destinationHash: destHash, transportId: upstream.hash, payload: h1.payload)
    return (try! relayedAnnounce.packed(), destHash)
}

/// Loop guard, no-answer half: a relay does NOT answer when the requester's transport_id equals our
/// next hop toward the destination (RNS Transport.py:2987). Isolated store, exhaustive at the moment
/// of the request send so any emitted transmit fails the test (removing the guard breaks this).
@Test @MainActor func relayLoopGuardEqualRequestorDoesNotAnswer() async {
    let relay = Identity(), upstream = Identity()
    let (announce, destHash) = makeRelayedAnnounce(via: upstream)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(InterfaceID("i0"), announce))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.nextHop == upstream.hash)

    // Requester IS our next hop → the guard must suppress the answer. Send in .off (the request also
    // mutates the dedup ring), then flip to .on with nothing after it: a stray transmit is then an
    // un-received delegate action that fails the store's exhaustive completeness check at teardown.
    await store.send(.received(InterfaceID("i0"),
                               makeRelayPathRequest(for: destHash, requestorTransportId: upstream.hash)))
    store.exhaustivity = .on
}

/// Loop guard, answer half: a different requestor transport_id → the relay answers with a pathResponse.
@Test @MainActor func relayLoopGuardDifferentRequestorAnswers() async {
    let relay = Identity(), upstream = Identity()
    let (announce, destHash) = makeRelayedAnnounce(via: upstream)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(InterfaceID("i0"), announce))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    let other = Data(repeating: 0x33, count: 16)
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i0"),
                               makeRelayPathRequest(for: destHash, requestorTransportId: other)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: captured.value!)?.context == .pathResponse)
}

/// End-to-end: a requester learns the destination from the relay's cache path-response.
@Test @MainActor func relayCachePathResponseIsLearnedByRequester() async {
    let relay = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let identityHash = Announce.parse(payload: Packet(raw: announceRaw)!.payload,
                                      destinationHash: destHash, contextFlagSet: false)!.identity.hash
    let relayStore = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    relayStore.exhaustivity = .off
    await relayStore.send(.interfaceConnected(InterfaceID("i0")))
    await relayStore.send(.setTransportIdentity(relay))
    await relayStore.send(.received(InterfaceID("i0"), announceRaw))
    await relayStore.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    let response = LockIsolated<Data?>(nil)
    await relayStore.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    await relayStore.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { response.setValue(raw); return true }
        return false
    }
    // Requester learns from the relay's path-response like any announce.
    let requester = TestStore(initialState: Transport.State()) { Transport() }
    requester.exhaustivity = .off
    await requester.send(.received(InterfaceID("up"), response.value!))
    await requester.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(requester.state.learned[destHash]?.identity.hash == identityHash)
    #expect(requester.state.learned[destHash]?.nextHop == relay.hash)   // reachable via the relay
}

// MARK: - Task 2: path-response gate

/// RNS Transport.py:1945 — a relay ADOPTS a path response into its path table but never
/// re-broadcasts it. Re-broadcasting turns one path request into a network-wide flood because
/// each path response carries a fresh random_hash that defeats blob dedup.
@Test @MainActor func pathResponseIsAdoptedButNotRebroadcast() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    // Two interfaces so a normal announce WOULD trigger a re-broadcast on the other interface.
    await store.send(.interfaceConnected(InterfaceID("a")))
    await store.send(.interfaceConnected(InterfaceID("b")))
    await store.send(.setTransportIdentity(relay))

    // Build a HEADER_2 path-response announce for a remote peer, arriving on interface "a".
    let peer = Identity()
    let destHash = Destination.hash(identityHash: peer.hash, appName: "test", aspects: ["pathresp"])
    let nameHash = Destination.nameHash(appName: "test", aspects: ["pathresp"])
    let randomHash = Announce.randomHash(now: 1, randomPrefix: Data(repeating: 0x01, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash,
                                        appData: Data([0xAB]))
    let response = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                          destinationType: .single, context: .pathResponse, contextFlag: false,
                          hops: 1, destinationHash: destHash,
                          transportId: Data(repeating: 0x09, count: 16), payload: payload)
    let responseRaw = try! response.packed()

    await store.send(.received(InterfaceID("a"), responseRaw))
    // Drain the pathLearned delegate (adoption still happens).
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    // Flip exhaustive ON last — any stray transmit (the re-broadcast bug) is an un-received
    // delegate action that fails teardown.
    store.exhaustivity = .on

    // The path was learned...
    #expect(store.state.learned[destHash] != nil)
    // ...but nothing was queued for re-broadcast.
    #expect(store.state.announceTable[destHash] == nil)
}

// MARK: - #4c-3b recursive path request re-broadcast

/// An opt-in relay re-broadcasts an unknown-path request onto every interface except the arrival
/// one, with payload dest ‖ our transport_id ‖ the same tag (RNS path_request:3044-3070).
/// De-relaying (setTransportIdentity(nil)) clears in-flight recursive searches, alongside the
/// announce/link tables — discoveryPathRequests is relay-only transient state.
@Test @MainActor func deRelayingClearsInFlightRecursiveSearches() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.discoveryPathRequests[unknown] != nil)
    await store.send(.setTransportIdentity(nil))
    #expect(store.state.discoveryPathRequests.isEmpty)
}

@Test @MainActor func recursiveRelayRebroadcastsUnknownPathRequest() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let tag = Data(repeating: 0x5A, count: 16)          // makePathRequest default tag
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action { captured.setValue((ifID, raw)); return true }
        return false
    }
    let (ifID, raw) = captured.value!
    #expect(ifID == InterfaceID("i1"))                  // re-broadcast on the non-arrival interface
    let p = Packet(raw: raw)!
    #expect(p.destinationHash == Transport.pathRequestDestinationHash)
    #expect(p.packetType == .data)
    #expect(p.payload == unknown + relay.hash + tag)    // dest ‖ our transport_id ‖ same tag
    #expect(store.state.discoveryPathRequests[unknown] != nil)
    // Exactly one re-broadcast (arrival interface excluded): a second transmit to i0 would be an
    // un-received delegate action caught at teardown. Makes the fan-out filter load-bearing.
    store.exhaustivity = .on
}

/// Recursion disabled (flag false) → no re-broadcast.
@Test @MainActor func recursionDisabledDoesNotRebroadcast() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))       // flag stays false
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: Data(repeating: 0x99, count: 16))))
    store.exhaustivity = .on
}

/// A non-relay (transportIdentity == nil) never re-broadcasts, even with the flag set.
@Test @MainActor func nonRelayDoesNotRebroadcast() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setRecursivePathRequests(true))    // flag on, but no transport identity
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: Data(repeating: 0x99, count: 16))))
    store.exhaustivity = .on
}

/// A known path (learned) never recurses — even if its announce cache is empty (RNS elif structure:
/// a path_table hit never falls through to should_search_for_unknown).
@Test @MainActor func knownButUncachedPathDoesNotRecurse() async {
    let relay = Identity()
    let dest = Data(repeating: 0x99, count: 16)
    var initial = Transport.State()
    initial.interfaces = [InterfaceID("i0"): .default, InterfaceID("i1"): .default]
    initial.transportIdentity = relay
    initial.recursivePathRequests = true
    initial.learned[dest] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil, interfaceID: InterfaceID("i1"),
        hops: 2, nextHop: nil, announceEmitted: 1000, learnedAt: Date(timeIntervalSince1970: 1000))
    // Note: announceCache[dest] is intentionally absent → the #4c-2 relay-cache branch is skipped.
    let store = TestStore(initialState: initial) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: dest)))
    store.exhaustivity = .on          // learned != nil → recursion suppressed → no transmit
}

/// An in-flight recursive search older than pathRequestTimeout is swept by maintenanceTick; a fresh
/// one survives (RNS stale discovery_path_requests cull, Transport.py:3060).
@Test @MainActor func staleRecursiveSearchIsSweptByMaintenanceTick() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.discoveryPathRequests[unknown] != nil)

    await store.send(.startMaintenance)
    // Not yet expired: a tick within the window keeps the entry.
    now.setValue(Date(timeIntervalSince1970: 5))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.discoveryPathRequests[unknown] != nil)
    // Past the timeout: the next tick sweeps it.
    now.setValue(Date(timeIntervalSince1970: Transport.pathRequestTimeout + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.discoveryPathRequests[unknown] == nil)
    await store.send(.stopMaintenance)
}

/// A second unknown-path request for the SAME destination (fresh tag) does not re-broadcast again
/// while the first search is in flight (RNS discovery_path_requests dedup, Transport.py:3045).
@Test @MainActor func duplicateDestinationDoesNotRebroadcastTwice() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    // First unknown request (tag A) → re-broadcasts.
    await store.send(.received(InterfaceID("i0"),
                               makePathRequest(for: unknown, tag: Data(repeating: 0xA1, count: 16))))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    // Second unknown request, same dest, different tag → deduped by discoveryPathRequests, no re-broadcast.
    await store.send(.received(InterfaceID("i0"),
                               makePathRequest(for: unknown, tag: Data(repeating: 0xB2, count: 16))))
    store.exhaustivity = .on
}

// MARK: - C3 queue discipline

/// The drain emits the FEWEST-HOP announce first, then the older of equal-hop entries
/// (RNS orders the announce queue by hops, then timestamp).
@Test @MainActor func drainEmitsFewestHopAnnounceFirst() async {
    var initial = Transport.State()
    let id = InterfaceID("i0")
    initial.interfaces[id] = .default
    initial.announceQueues[id] = [
        .init(raw: Data("far".utf8),   hops: 5, queuedAt: Date(timeIntervalSince1970: 10)),
        .init(raw: Data("near".utf8),  hops: 1, queuedAt: Date(timeIntervalSince1970: 30)),
        .init(raw: Data("near2".utf8), hops: 1, queuedAt: Date(timeIntervalSince1970: 20)),
    ]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    let out = LockIsolated<Data?>(nil)
    await store.send(.announceQueueDrainDue(id))
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { out.setValue(d); return true }
        return false
    }
    // hops 1 beats hops 5; between the two hops-1 entries the OLDER (t=20) wins.
    #expect(out.value == Data("near2".utf8))
    #expect(store.state.announceQueues[id]?.count == 2)
}

/// A full queue drops further announces rather than growing without bound.
@Test @MainActor func announceQueueDropsWhenAtCapacity() async {
    var initial = Transport.State()
    let id = InterfaceID("iSlow")
    initial.interfaces[id] = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    initial.interfaces[InterfaceID("i0")] = .default
    initial.transportIdentity = Identity()
    // Saturate the queue and close the pacing window so the next announce must queue.
    initial.announceQueues[id] = Array(
        repeating: .init(raw: Data([0xAA]), hops: 3,
                         queuedAt: Date(timeIntervalSince1970: 0)),
        count: Transport.announceQueueLimit)
    initial.announceAllowedAt[id] = Date(timeIntervalSince1970: 9_999)
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.randomBytes = RandomBytesGenerator { _ in Data([0]) }
    }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.receive(.announceRetransmitDue(destinationHash: destHash))
    #expect(store.state.announceQueues[id]?.count == Transport.announceQueueLimit)  // no growth
}

/// maintenanceTick drops queued announces older than QUEUED_ANNOUNCE_LIFE and removes the
/// queue entry entirely once empty.
@Test @MainActor func maintenanceTickExpiresStaleQueuedAnnounces() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    var initial = Transport.State()
    let id = InterfaceID("i0")
    initial.interfaces[id] = .default
    initial.announceQueues[id] = [
        .init(raw: Data("old".utf8),   hops: 1, queuedAt: Date(timeIntervalSince1970: 0)),
        .init(raw: Data("fresh".utf8), hops: 1, queuedAt: Date(timeIntervalSince1970: 80_000)),
    ]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.queuedAnnounceLife + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.announceQueues[id]?.count == 1)          // only "old" expired
    // Push past the fresh one's lifetime too: the queue entry disappears entirely.
    now.setValue(Date(timeIntervalSince1970: 80_000 + Transport.queuedAnnounceLife + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.announceQueues[id] == nil)
    await store.send(.stopMaintenance)
}

/// When an interface's pacing queue already has a backlog, retransmitDue must NOT take the
/// send-now branch even if the pacing window is open (RNS Transport.py:1281-1282, Finding 1).
/// The drain is the sole emitter while a backlog exists so the queue stays self-serializing.
///
/// Scenario: interface queue has a bystander entry for destB; pacing window is open (no
/// allowedAt set). retransmitDue fires for destA. Without the queueEmpty guard the window
/// check passes and destA would be transmitted directly (queue stays at 1, just destB).
/// With the guard the else-branch is taken, destA is enqueued alongside destB (count = 2).
@Test @MainActor func retransmitDueDoesNotBypassQueueWhenBacklogExists() async {
    let relay = Identity()
    let slowID = InterfaceID("iSlow")
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    // Build destA's announce and its destination hash.
    let (rawA, destHashA) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                               randomPrefix: Data([0xAA, 0, 0, 0, 0]))
    let destHashB = Data(repeating: 0xBB, count: 16)

    var initial = Transport.State()
    initial.interfaces[slowID] = slow
    initial.interfaces[InterfaceID("i0")] = .default
    initial.transportIdentity = relay
    // Pre-populate the announce table so retransmitDue processes destA.
    initial.announceTable[destHashA] = Transport.State.PendingAnnounce(
        raw: rawA, arrivalInterface: InterfaceID("i0"), rebroadcastHops: 3, rebroadcasts: 0)
    // Pre-populate learned so emitted lookup works.
    initial.learned[destHashA] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil,
        interfaceID: InterfaceID("i0"), hops: 2, nextHop: destHashA,
        announceEmitted: 1000)
    // Pre-populate queue with a bystander for destB.
    initial.announceQueues[slowID] = [
        Transport.State.QueuedAnnounce(raw: Data("bystander".utf8), hops: 5, queuedAt: Date(),
                                       destination: destHashB, emitted: 500),
    ]
    // Leave announceAllowedAt[slowID] unset → window is open (distantPast).

    let clock = TestClock()
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
    }
    store.exhaustivity = .off

    // Fire retransmitDue directly (no jitter needed — we own the announce table entry).
    await store.send(.announceRetransmitDue(destinationHash: destHashA))
    await store.skipReceivedActions(strict: false)

    // Key assertion: destA must have been QUEUED (not sent directly).
    // Queue should now have 2 entries: bystander destB + newly-enqueued destA.
    let queue = store.state.announceQueues[slowID] ?? []
    #expect(queue.count == 2, "expected bystander + destA in queue (got \(queue.count)); direct send would leave only bystander")
    #expect(queue.contains { $0.destination == destHashA }, "destA must be in queue, not sent directly")
}

/// Both retransmit rounds of a single-destination announce lifecycle on a slow interface
/// produce AT MOST ONE queued entry for that destination — not two.
///
/// By pre-closing the pacing window we ensure BOTH rounds of the 2-try lifecycle must queue.
/// Without the per-destination collapse (Finding 2), both rounds would append a separate entry
/// and the queue would hold two entries for the same destination.
/// With the fix only the newer entry survives (upsert), so the queue holds exactly one.
@Test @MainActor func bothRetransmitRoundsLeaveAtMostOneQueuedEntryPerDestination() async {
    // Pre-close the pacing window for iSlow so BOTH retransmit rounds are forced to queue.
    // With a 9+ s pacing window (8 kbps, 2% cap) and a window pinned to t=9999, the first
    // retransmitDue at ~0.25 s AND the retry at ~5.75 s both land inside the closed window.
    var initial = Transport.State()
    let slowID = InterfaceID("iSlow")
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    initial.interfaces[slowID] = slow
    initial.interfaces[InterfaceID("i0")] = .default
    initial.transportIdentity = Identity()
    // Close the window so every retransmitDue must queue rather than send directly.
    initial.announceAllowedAt[slowID] = Date(timeIntervalSince1970: 9_999)

    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                             randomPrefix: Data([1, 0, 0, 0, 0]))
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = clockTrackingDate(clock)
        $0.randomBytes = RandomBytesGenerator { _ in Data([128]) }  // jitter = 0.25 s
    }
    store.exhaustivity = .off

    // Deliver the announce — schedules retransmitDue round 1 at ~0.25 s.
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    // Round 1 (~0.25 s): window still closed → enqueues. Schedules retry at +5.5 s.
    await clock.advance(by: .seconds(0.25))
    await store.skipReceivedActions(strict: false)
    let afterRound1 = store.state.announceQueues[slowID]?.count ?? 0
    #expect(afterRound1 == 1, "expected 1 entry after round 1, got \(afterRound1)")

    // Round 2 (+5.5 s retry): window still closed → must upsert the SAME destination,
    // not append a second entry. Queue must still hold exactly 1 entry.
    await clock.advance(by: .seconds(5.5))
    await store.skipReceivedActions(strict: false)
    let afterRound2 = store.state.announceQueues[slowID]?.count ?? 0
    #expect(afterRound2 == 1, "expected 1 entry after round 2, got \(afterRound2)")

    await store.send(.stopMaintenance)
}

// MARK: - C4 announce ingress control (pure primitives)

/// Ingress constants are the reference values (RNS Interface.py:58-92).
@Test func ingressControlConstantsMatchReference() {
    #expect(Transport.iaFreqSamples == 48)
    #expect(Transport.arFreqDecay == 10)
    #expect(Transport.maxHeldAnnounces == 256)
    #expect(Transport.icNewTime == 7200)
    #expect(Transport.icBurstFreqNew == 3)
    #expect(Transport.icBurstFreq == 10)
    #expect(Transport.icBurstHold == 15)
    #expect(Transport.icBurstPenalty == 15)
    #expect(Transport.icHeldReleaseInterval == 5)
    #expect(Transport.icDequeMinSample == 2)
}

/// Frequency is samples/span, and is 0 until MORE THAN icDequeMinSample samples exist
/// (RNS `if not n > IC_DEQUE_MIN_SAMPLE: return 0`, Interface.py:277-278) — so 2 samples
/// still yields 0 and cannot trip a burst.
@Test func announceFrequencyNeedsMoreThanMinimumSamples() {
    let t0 = Date(timeIntervalSince1970: 100)
    #expect(Transport.announceFrequency(samples: [], now: t0) == 0)
    #expect(Transport.announceFrequency(samples: [t0, t0], now: t0.addingTimeInterval(1)) == 0)
    // 3 samples spanning 1 s → 3 Hz.
    let s = [t0, t0.addingTimeInterval(0.5), t0.addingTimeInterval(0.9)]
    #expect(Transport.announceFrequency(samples: s, now: t0.addingTimeInterval(1)) == 3.0)
}

/// A non-positive span yields 0 rather than dividing by zero (Interface.py:281).
@Test func announceFrequencyGuardsNonPositiveSpan() {
    let t0 = Date(timeIntervalSince1970: 100)
    #expect(Transport.announceFrequency(samples: [t0, t0, t0], now: t0) == 0)
}

/// A young interface is held to the stricter threshold (RNS ic_burst_freq_new for
/// age < IC_NEW_TIME, Interface.py:154).
@Test func burstThresholdIsStricterForYoungInterfaces() {
    #expect(Transport.ingressBurstThreshold(interfaceAge: 60) == 3)
    #expect(Transport.ingressBurstThreshold(interfaceAge: 7199) == 3)
    #expect(Transport.ingressBurstThreshold(interfaceAge: 7200) == 10)
    #expect(Transport.ingressBurstThreshold(interfaceAge: 100_000) == 10)
}

/// Crossing the threshold activates the burst, stamps activatedAt, and pushes heldRelease
/// out by the penalty (Interface.py:163-168).
@Test func exceedingThresholdActivatesBurstAndSetsPenalty() {
    let t0 = Date(timeIntervalSince1970: 1000)
    // 5 samples over 1 s = 5 Hz > 3 Hz young threshold.
    let s = (0..<5).map { t0.addingTimeInterval(Double($0) * 0.2) }
    let idle = Transport.IngressBurst()
    let r = Transport.shouldIngressLimit(samples: s, now: t0.addingTimeInterval(1),
                                         interfaceAge: 60, burst: idle)
    #expect(r.limit == true)
    #expect(r.burst.active == true)
    #expect(r.burst.activatedAt == t0.addingTimeInterval(1))
    #expect(r.burst.heldRelease == t0.addingTimeInterval(1 + Transport.icBurstPenalty))
}

/// Below the threshold with no active burst, nothing is limited and no state changes.
@Test func belowThresholdDoesNotLimit() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let s = (0..<3).map { t0.addingTimeInterval(Double($0) * 5) }   // 3 samples / 10 s = 0.3 Hz
    let idle = Transport.IngressBurst()
    let r = Transport.shouldIngressLimit(samples: s, now: t0.addingTimeInterval(10),
                                         interfaceAge: 60, burst: idle)
    #expect(r.limit == false)
    #expect(r.burst.active == false)
}

/// An active burst keeps limiting until BOTH the rate has fallen below the threshold AND
/// icBurstHold has elapsed since activation. Crucially, the call that DEACTIVATES still
/// returns limit == true (RNS returns True on that path, Interface.py:157-161) — the
/// announce that ends the burst is itself still held.
@Test func activeBurstDeactivatesOnlyAfterHoldElapsesAndStillLimitsThatCall() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let quiet = [t0, t0.addingTimeInterval(4), t0.addingTimeInterval(8)]   // 3/9 s = 0.33 Hz
    let active = Transport.IngressBurst(active: true, activatedAt: t0,
                                        heldRelease: t0.addingTimeInterval(15))
    // Rate is low but the hold window has NOT elapsed → stays active.
    let early = Transport.shouldIngressLimit(samples: quiet, now: t0.addingTimeInterval(9),
                                             interfaceAge: 60, burst: active)
    #expect(early.limit == true)
    #expect(early.burst.active == true)
    // Past the hold window with a low rate → deactivates, but THIS call still limits.
    let late = Transport.shouldIngressLimit(samples: quiet, now: t0.addingTimeInterval(16),
                                            interfaceAge: 60, burst: active)
    #expect(late.limit == true)
    #expect(late.burst.active == false)
}

/// A still-hot rate keeps an active burst active past the hold window.
@Test func activeBurstStaysActiveWhileRateRemainsHigh() {
    let t0 = Date(timeIntervalSince1970: 1000)
    // 10 samples in the second before now=t0+20: oldest=t0+19, span=1 s → 10 Hz.
    let hot = (0..<10).map { t0.addingTimeInterval(19 + Double($0) * 0.1) }
    let active = Transport.IngressBurst(active: true, activatedAt: t0,
                                        heldRelease: t0.addingTimeInterval(15))
    let r = Transport.shouldIngressLimit(samples: hot, now: t0.addingTimeInterval(20),
                                         interfaceAge: 60, burst: active)
    #expect(r.limit == true)
    #expect(r.burst.active == true)
}

// MARK: - C4 Task 2: receive-side gate

/// Under a burst, an announce for an UNKNOWN destination is held rather than admitted:
/// no path is learned and no blob is recorded, so the later release is not a replay.
@Test @MainActor func burstHoldsAnnounceForUnknownDestination() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let i0 = InterfaceID("i0")
    await store.send(.interfaceConnected(i0, .default))
    // Drive the arrival rate over the 3 Hz young-interface threshold with distinct announces.
    for k in 0..<6 {
        now.setValue(Date(timeIntervalSince1970: 1000 + Double(k) * 0.1))
        let (raw, _) = makeAnnouncePacket(hops: 2, emitted: UInt64(1000 + k),
                                          randomPrefix: Data([UInt8(k + 1), 0, 0, 0, 0]))
        await store.send(.received(i0, raw))
    }
    #expect(store.state.ingressBursts[i0]?.active == true)
    #expect((store.state.heldAnnounces[i0]?.count ?? 0) > 0)
    // A held announce must not have been admitted: no path, and its blob is unrecorded.
    let heldDest = store.state.heldAnnounces[i0]!.keys.first!
    #expect(store.state.learned[heldDest] == nil)
    #expect(store.state.announceBlobs[heldDest] == nil)
}

/// C4/C5 hold STORAGE: on an IFAC interface the burst hold stores the MASKED bytes (the
/// verbatim `.received` payload), not the unmasked plain bytes.
///
/// This is the one claim the whole C4/C5 placement decision rests on (Transport.swift:333
/// stores `raw: data`). Without this property, releasing a held announce on an IFAC
/// interface would pass de-masked bytes back through `.received`, which re-runs the IFAC
/// gate, finds no flag set, and silently discards the announce — the exact reference RNS
/// bug documented at Transport.swift:236-237.
///
/// MUTATION-PROVEN: changing `raw: data` to `raw: plain` compiles and keeps every OTHER
/// test green while making this test fail — because `plain` == `data` on plain interfaces
/// (every other C4 test) but differs on IFAC interfaces.
@Test @MainActor func burstHoldsAnnounceOnIFACInterfaceStoringMaskedBytes() async {
    let ifac = IFAC(networkName: "hold-xval", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.default
    profile.ifac = ifac

    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let i0 = InterfaceID("i0")
    await store.send(.interfaceConnected(i0, profile))
    // Drive the arrival rate over the 3 Hz young-interface threshold with distinct masked announces.
    // Track the raw and masked bytes for EACH packet so we can look up any held one after.
    var sentMasked: [Data: Data] = [:]   // destHash → masked bytes
    for k in 0..<6 {
        now.setValue(Date(timeIntervalSince1970: 1000 + Double(k) * 0.1))
        let (raw, dest) = makeAnnouncePacket(hops: 2, emitted: UInt64(1000 + k),
                                             randomPrefix: Data([UInt8(k + 1), 0, 0, 0, 0]))
        let masked = ifac.protect(raw)
        sentMasked[dest] = masked
        await store.send(.received(i0, masked))
    }
    #expect(store.state.ingressBursts[i0]?.active == true)
    #expect((store.state.heldAnnounces[i0]?.count ?? 0) > 0)

    // THE KEY ASSERTION: the stored bytes must be the original masked bytes, not the
    // unmasked plain. Bit 7 of byte 0 is always set on IFAC wire bytes (IFAC.protect
    // forces it at Transport.py:1081/1091). Check via both the flag bit and byte equality
    // against the masked packet we sent for this specific held destination.
    let heldDest = store.state.heldAnnounces[i0]!.keys.first!
    let storedRaw = store.state.heldAnnounces[i0]![heldDest]!.raw
    #expect(storedRaw.first! & 0x80 == 0x80, "stored bytes must be masked (bit 7 set)")
    #expect(storedRaw == sentMasked[heldDest]!, "stored bytes must equal the verbatim masked input")
}

/// An announce for a destination we ALREADY have a path to is never held, even mid-burst
/// (RNS limits only unknown destinations — known ones are governed by announce rate limiting).
@Test @MainActor func burstDoesNotHoldAnnounceForKnownDestination() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let i0 = InterfaceID("i0")
    await store.send(.interfaceConnected(i0, .default))
    // Learn a path for this identity BEFORE the burst.
    let known = Identity()
    let (first, knownDest) = makeAnnouncePacket(identity: known, appName: "app", aspects: ["s"],
                                                hops: 2, emitted: 1,
                                                randomPrefix: Data([9, 0, 0, 0, 0]))
    await store.send(.received(i0, first))
    #expect(store.state.learned[knownDest] != nil)
    // Now drive a burst with OTHER destinations.
    for k in 0..<6 {
        now.setValue(Date(timeIntervalSince1970: 1000 + Double(k) * 0.1))
        let (raw, _) = makeAnnouncePacket(hops: 2, emitted: UInt64(2000 + k),
                                          randomPrefix: Data([UInt8(k + 1), 0, 0, 0, 0]))
        await store.send(.received(i0, raw))
    }
    #expect(store.state.ingressBursts[i0]?.active == true)
    // A fresh announce for the KNOWN destination is still admitted, not held.
    now.setValue(Date(timeIntervalSince1970: 1002))
    let (again, _) = makeAnnouncePacket(identity: known, appName: "app", aspects: ["s"],
                                        hops: 1, emitted: 5000,
                                        randomPrefix: Data([8, 0, 0, 0, 0]))
    await store.send(.received(i0, again))
    #expect(store.state.heldAnnounces[i0]?[knownDest] == nil)
    #expect(store.state.learned[knownDest]?.hops == 1)          // the better path was adopted
}

/// An announce for a destination we have an outstanding path request for is never held —
/// we asked for it (RNS skips the ingress check for pending path requests, Transport.py:1759).
/// The exemption is established via .requestPath, which writes pathRequests (the LOCAL gate
/// table, Transport.path_requests). Seeding discoveryPathRequests directly was the original
/// approach but never proved the state was reachable from a leaf node.
@Test @MainActor func pendingPathRequestExemptsAnnounceFromHolding() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let i0 = InterfaceID("i0")
    let wanted = Identity()
    let (raw, wantedDest) = makeAnnouncePacket(identity: wanted, appName: "app", aspects: ["s"],
                                               hops: 2, emitted: 7000,
                                               randomPrefix: Data([7, 0, 0, 0, 0]))
    var initial = Transport.State()
    // Pre-arm an active burst so the gate would otherwise hold.
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 999),
        heldRelease: Date(timeIntervalSince1970: 1014))
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
        $0.randomBytes = RandomBytesGenerator { _ in Data(repeating: 0xAB, count: 16) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i0, .default))
    // Drive the exemption via .requestPath — this is the only production write site for
    // pathRequests and is reachable on leaf nodes (transportIdentity == nil).
    await store.send(.requestPath(destinationHash: wantedDest))
    #expect(store.state.pathRequests[wantedDest] != nil)         // gate entry recorded
    await store.send(.received(i0, raw))
    #expect(store.state.heldAnnounces[i0]?[wantedDest] == nil)  // exempt
    #expect(store.state.learned[wantedDest] != nil)             // admitted normally
}

/// Holding replaces an existing entry for the same destination and never exceeds the cap;
/// an announce at the hop limit is dropped rather than held (RNS hold_announce).
@Test @MainActor func holdReplacesPerDestinationAndRespectsCapAndHopLimit() async {
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 0),
        heldRelease: Date(timeIntervalSince1970: 15))
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 1) }
    }
    store.exhaustivity = .off
    let id = Identity()
    let (a1, dest) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"],
                                        hops: 4, emitted: 1, randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, _)    = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"],
                                        hops: 2, emitted: 2, randomPrefix: Data([2, 0, 0, 0, 0]))
    await store.send(.received(i0, a1))
    await store.send(.received(i0, a2))
    #expect(store.state.heldAnnounces[i0]?.count == 1)           // replaced, not appended
    #expect(store.state.heldAnnounces[i0]?[dest]?.hops == 2)     // newest wins

    // An announce at the hop limit is dropped outright, not held.
    let (far, farDest) = makeAnnouncePacket(hops: UInt8(Transport.ingressHoldHopLimit),
                                            emitted: 3, randomPrefix: Data([3, 0, 0, 0, 0]))
    await store.send(.received(i0, far))
    #expect(store.state.heldAnnounces[i0]?[farDest] == nil)
}

/// Disconnecting an interface drops all of its ingress state.
@Test @MainActor func disconnectClearsIngressState() async {
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.announceArrivals[i0] = [Date(timeIntervalSince1970: 1)]
    initial.ingressBursts[i0] = Transport.IngressBurst(active: true)
    initial.heldAnnounces[i0] = [Data([0xAB]): .init(raw: Data([0xCD]), hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceDisconnected(i0))
    #expect(store.state.announceArrivals[i0] == nil)
    #expect(store.state.ingressBursts[i0] == nil)
    #expect(store.state.heldAnnounces[i0] == nil)
    #expect(store.state.interfaceConnectedAt[i0] == nil)
}

// MARK: - #C4 Task 3: release held announces

/// Once the rate subsides and the penalty has elapsed, the release re-injects the FEWEST-HOP
/// held announce through the FULL receive path.
///
/// Convergence, not an exemption: the first re-injection still meets an ACTIVE burst, so the
/// gate holds it again (RNS should_ingress_limit returns `limit` even on the call that flips
/// the burst off — Task 1 pins that asymmetry). That bounce is what deactivates the burst;
/// the NEXT release, spaced icHeldReleaseInterval apart, is admitted and the path is learned.
@Test @MainActor func heldAnnounceIsReleasedFewestHopsFirstAndAdmitted() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 900),
        heldRelease: Date(timeIntervalSince1970: 1000))
    // Burst deactivation also needs >= icDequeMinSample arrivals on record, so seed one that
    // is still inside the arFreqDecay window. Two samples keep the measured rate at 0.
    initial.announceArrivals[i0] = [Date(timeIntervalSince1970: 998)]
    let far = Identity(), near = Identity()
    let (farRaw, farDest)   = makeAnnouncePacket(identity: far, appName: "app", aspects: ["s"],
                                                 hops: 5, emitted: 1,
                                                 randomPrefix: Data([1, 0, 0, 0, 0]))
    let (nearRaw, nearDest) = makeAnnouncePacket(identity: near, appName: "app", aspects: ["s"],
                                                 hops: 1, emitted: 2,
                                                 randomPrefix: Data([2, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [farDest:  .init(raw: farRaw,  hops: 5),
                                 nearDest: .init(raw: nearRaw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off

    // First release: fewest hops is picked and re-injected, but the still-active burst holds
    // it again. The re-injection is delivered as an effect, so await it before asserting.
    now.setValue(Date(timeIntervalSince1970: 1001))          // past heldRelease, rate is 0
    await store.send(.heldAnnounceReleaseDue(i0))
    await store.receive { if case .received = $0 { return true }; return false }
    #expect(store.state.learned[nearDest] == nil)            // bounced: not admitted yet
    #expect(store.state.heldAnnounces[i0]?.count == 2)       // back under hold
    #expect(store.state.ingressBursts[i0]?.active == false)  // ...but the burst is now off

    // Second release, one spacing interval later: the burst is inactive, so the same fewest-hop
    // announce is admitted on re-entry and its path is learned.
    now.setValue(Date(timeIntervalSince1970: 1007))
    await store.send(.heldAnnounceReleaseDue(i0))
    await store.receive { if case .received = $0 { return true }; return false }
    #expect(store.state.learned[nearDest] != nil)            // fewest hops released first
    #expect(store.state.learned[farDest] == nil)             // still held
    #expect(store.state.heldAnnounces[i0]?.count == 1)
}

/// A release is not attempted before the penalty elapses (RNS gates on ic_held_release).
@Test @MainActor func releaseWaitsForThePenaltyToElapse() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 990),
        heldRelease: Date(timeIntervalSince1970: 1015))       // penalty not yet elapsed
    let (raw, dest) = makeAnnouncePacket(hops: 1, emitted: 1, randomPrefix: Data([1, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [dest: .init(raw: raw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.heldAnnounceReleaseDue(i0))
    #expect(store.state.heldAnnounces[i0]?.count == 1)        // still held
    #expect(store.state.learned[dest] == nil)
}

/// While the arrival rate is still above the threshold, releases stay blocked even past
/// the penalty (RNS re-checks the frequency inside process_held_announces).
@Test @MainActor func releaseIsBlockedWhileRateStaysHot() async {
    let clock = TestClock()
    let t0 = Date(timeIntervalSince1970: 1000)
    let now = LockIsolated(t0.addingTimeInterval(1))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: t0, heldRelease: t0)
    initial.announceArrivals[i0] = (0..<10).map { t0.addingTimeInterval(Double($0) * 0.1) }
    let (raw, dest) = makeAnnouncePacket(hops: 1, emitted: 1, randomPrefix: Data([1, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [dest: .init(raw: raw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.heldAnnounceReleaseDue(i0))
    #expect(store.state.heldAnnounces[i0]?.count == 1)        // rate still ~10 Hz → blocked
    #expect(store.state.learned[dest] == nil)
}

// MARK: - #C4 C1 fix: leaf-node pathRequests gate

/// C1 regression test: a LEAF node (transportIdentity == nil) can call .requestPath, and
/// the resulting pathRequests entry causes the arriving path-response announce to be admitted
/// even mid-burst. Under the old code (exemption only from discoveryPathRequests, which is
/// never written by a leaf) the announce would be held indefinitely.
@Test @MainActor func leafNodeRequestPathExemptsIncomingAnnounceFromBurst() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let i0 = InterfaceID("i0")
    // transportIdentity == nil → leaf node (LXMFNode/app configuration)
    var initial = Transport.State()
    // Pre-arm an active burst so any unknown-dest announce would be held.
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 999),
        heldRelease: Date(timeIntervalSince1970: 1014))
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
        $0.randomBytes = RandomBytesGenerator { _ in Data(repeating: 0xCC, count: 16) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i0, .default))
    // Confirm this is a leaf node.
    #expect(store.state.transportIdentity == nil)
    // Leaf issues a path request — this is the ONLY write site for pathRequests on a leaf.
    let target = Identity()
    let (announceRaw, targetDest) = makeAnnouncePacket(identity: target, appName: "app", aspects: ["s"],
                                                        hops: 2, emitted: 9000,
                                                        randomPrefix: Data([9, 0, 0, 0, 0]))
    await store.send(.requestPath(destinationHash: targetDest))
    // discoveryPathRequests is NOT written (relay-only); pathRequests IS written.
    #expect(store.state.discoveryPathRequests[targetDest] == nil)
    #expect(store.state.pathRequests[targetDest] != nil)
    // Path-response announce arrives mid-burst → must be admitted, not held.
    await store.send(.received(i0, announceRaw))
    #expect(store.state.heldAnnounces[i0]?[targetDest] == nil)  // NOT held
    #expect(store.state.learned[targetDest] != nil)             // path learned
}

// MARK: - #C4 I1 fix: release timer flood-resistance

/// I1 regression test: with a burst active and its penalty already elapsed (heldRelease in
/// the past), holding a new announce must arm a release timer at least icHeldReleaseInterval
/// (5 s) in the future, not 0 s.
///
/// Old code: max(0, heldRelease - now) where heldRelease < now → releaseIn=0 → 0s sleep.
///   After clock.advance(5s): both the 0s sleep AND a rescheduled 5s sleep fire →
///   TWO heldAnnounceReleaseDue dispatches. The 0s fires first → handler bumps heldRelease
///   to t(2005) → second fire is BLOCKED (now < heldRelease) but the action is still
///   dispatched and in the queue.
///
/// Fix: max(icHeldReleaseInterval, ...) → releaseIn=5 → 5s sleep.
///   After clock.advance(5s): exactly ONE heldAnnounceReleaseDue dispatch (the 5s timer).
///   Handler bumps heldRelease to t(2005), schedules new timer at T+10 (in-flight).
///
/// Test: advance 5s, consume EXACTLY ONE heldAnnounceReleaseDue, then skipInFlightEffects.
/// With old code: second action is dispatched (queue, not in-flight) → not cancelled by
///   skipInFlightEffects → unhandled at test end → FAIL.
/// With new code: no second action → T+10 timer in-flight → skipInFlightEffects cancels →
///   PASS.
///
/// Setup: activatedAt=RECENT (hold NOT elapsed) so shouldIngressLimit cannot deactivate the
/// burst during .received → burst stays active → all re-injections are re-held, not admitted.
@Test @MainActor func holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 2000))
    let i0 = InterfaceID("i0")
    var initial = Transport.State()
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    // activatedAt=t(1999): hold check: now(2000) > 1999+15=2014 → FALSE → hold NOT elapsed.
    // Burst stays ACTIVE through all re-injections (shouldIngressLimit cannot deactivate).
    // heldRelease=t(1998) (PAST): old code max(0,1998-2000)=0; fix max(5,1998-2000)=5.
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 1999),
        heldRelease: Date(timeIntervalSince1970: 1998))
    // Pre-seed one held announce for heldAnnounceReleaseDue to release (bumps heldRelease).
    let (existingRaw, existingDest) = makeAnnouncePacket(hops: 1, emitted: 4000,
                                                          randomPrefix: Data([4, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [existingDest: .init(raw: existingRaw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    // Hold a new announce — arms the release timer.
    // Old code: releaseIn=max(0,-2)=0 → 0s sleep. Fix: releaseIn=max(5,-2)=5 → 5s sleep.
    let (raw, dest) = makeAnnouncePacket(hops: 2, emitted: 5000, randomPrefix: Data([5, 0, 0, 0, 0]))
    await store.send(.received(i0, raw))
    #expect(store.state.heldAnnounces[i0]?[dest] != nil)   // held as expected

    // Advance exactly icHeldReleaseInterval (5 s).
    // Old code: TWO timer fires result — the 0s fire at T=0 (successful release, bumps
    //   heldRelease to t(2005)), then a rescheduled 5s timer fires at T=5 (BLOCKED since
    //   now=t(2000) < heldRelease=t(2005)). After advance(5s): 2 heldAnnounceReleaseDue
    //   in queue plus the inner .received re-injection from T=0.
    // New code: ONE timer fire — the 5s timer at T=5 (successful). After advance(5s): 1
    //   heldAnnounceReleaseDue in queue plus the inner .received re-injection.
    await clock.advance(by: .seconds(Transport.icHeldReleaseInterval))

    // With .off exhaustivity, consume the FIRST heldAnnounceReleaseDue and its re-injection.
    // This consumes the T=0 fire for old code, or the T=5 fire for new code.
    await store.receive { if case .heldAnnounceReleaseDue = $0 { return true }; return false }
    await store.receive { if case .received = $0 { return true }; return false }

    // Switch to .on exhaustivity: any remaining unhandled actions now cause test failure.
    // Old code: SECOND heldAnnounceReleaseDue (T=5, blocked) is still in the action queue
    //   — it was dispatched (timer fired), not cancelled. .on exhaustivity catches it → FAIL.
    // New code: NO second action. Only an in-flight T+10 timer (sleeping). skipInFlightEffects
    //   cancels it → test ends cleanly → PASS.
    store.exhaustivity = .on
    await store.skipInFlightEffects()
}

// MARK: - #C5 IFAC inbound gate

/// An IFAC-protected packet arriving on a matching interface is unmasked and processed
/// normally (the path is learned from the recovered announce).
@Test @MainActor func ifacProtectedAnnounceIsUnmaskedAndProcessed() async {
    let ifac = IFAC(networkName: "xnet", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.default
    profile.ifac = ifac
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), profile))
    await store.send(.received(InterfaceID("i0"), ifac.protect(raw)))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash] != nil)
}

/// A packet from a DIFFERENT network is dropped — no path learned at all, under any key.
///
/// The drop assertion is `learned.isEmpty`, not `learned[destHash] == nil`: `protect()` inserts
/// `size` bytes of access code after the 2-byte header, so a masked packet that slipped past the
/// guard would parse with a GARBLED destination hash and would file any path under the wrong key.
/// The keyed form would read nil for that reason alone; the emptiness form is the stronger one.
///
/// KNOWN LIMIT — this assertion pins the required behaviour but does NOT discriminate removal of
/// the `unprotect`-nil guard. Verified empirically, not assumed: see the note on
/// `protectedPacketOnPlainInterfaceIsDropped` below for the measured mechanism. Do not mistake
/// this for a mutation-proven test.
///
/// The positive control at the end proves the store is capable of learning on this interface,
/// so the drop assertion is not vacuous.
@Test @MainActor func packetFromAnotherIFACNetworkIsDropped() async {
    let ours = IFAC(networkName: "ours", passphrase: nil, size: 16)!
    let theirs = IFAC(networkName: "theirs", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.default
    profile.ifac = ours
    let (foreignRaw, _) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), profile))
    await store.send(.received(InterfaceID("i0"), theirs.protect(foreignRaw)))
    #expect(store.state.learned.isEmpty)          // nothing learned, under ANY key

    // Positive control: the SAME store on the SAME interface DOES admit a packet correctly
    // protected for OUR network. Without this the drop assertion above could pass vacuously
    // (e.g. a mis-set-up store in which nothing could ever be learned).
    let (ourRaw, ourDest) = makeAnnouncePacket(hops: 2, emitted: 2000)
    await store.send(.received(InterfaceID("i0"), ours.protect(ourRaw)))
    await store.receive(.delegate(.pathLearned(destinationHash: ourDest, hops: 2)))
    #expect(store.state.learned[ourDest] != nil)
}

/// An UNPROTECTED packet on an IFAC interface is dropped (RNS Transport.py:1478-1480).
///
/// MUTATION-PROVEN: the adversarial input is a VALID announce packet with the IFAC flag set
/// in byte 0 (`raw[0] |= 0x80`). `Packet.init(raw:)` reads only bits 6,5,4,3-2,1-0 of byte 0
/// (Sources/ReTiCA/Packet/Packet.swift:75-79) and never bit 7, so the flagged packet parses
/// into a packet with the correct destination hash and a valid announce signature. Without the
/// `unprotect`-nil guard, `.pathLearned` fires; with it, the packet is dropped before parsing.
/// Discriminates removal of the guard: `guard let unmasked = ifac.unprotect(data) else { return .none }`.
///
/// The positive control at the end proves the store CAN learn on this interface, so the
/// `learned.isEmpty` drop assertion is not vacuous.
@Test @MainActor func plainPacketOnIFACInterfaceIsDropped() async {
    let ifac = IFAC(networkName: "xnet", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.default
    profile.ifac = ifac
    let (raw, _) = makeAnnouncePacket(hops: 2, emitted: 1000)
    // Flag-set-but-otherwise-valid packet: byte 0 gets bit 7 set, everything else intact.
    // This parses correctly (bit 7 ignored) and has a valid signature — the only gate is
    // the unprotect() call which returns nil for a non-IFAC-masked packet.
    var flagged = raw
    flagged[0] |= 0x80
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), profile))
    await store.send(.received(InterfaceID("i0"), flagged))
    #expect(store.state.learned.isEmpty)          // nothing learned, under ANY key

    // Positive control: the SAME store DOES admit a correctly IFAC-protected packet.
    // Without this the drop assertion above could pass vacuously.
    let (raw2, dest2) = makeAnnouncePacket(hops: 2, emitted: 2000)
    await store.send(.received(InterfaceID("i0"), ifac.protect(raw2)))
    await store.receive(.delegate(.pathLearned(destinationHash: dest2, hops: 2)))
    #expect(store.state.learned[dest2] != nil)
}

/// A PROTECTED packet on a NON-IFAC interface is dropped (RNS Transport.py:1482-1486).
///
/// MUTATION-PROVEN: the adversarial input is a VALID announce packet with bit 7 of byte 0 set
/// (`raw[0] |= 0x80`). `Packet.init(raw:)` reads only bits 6,5,4,3-2,1-0 of byte 0
/// (Sources/ReTiCA/Packet/Packet.swift:75-79) and never bit 7, so the packet parses with the
/// correct destination hash and a valid Ed25519 signature. Without the bit-7 flag guard,
/// `pathLearned` fires; with it, the packet is rejected before parsing.
/// Discriminates removal of the guard: `guard data.first.map({ $0 & 0x80 == 0 }) ?? false else { return .none }`.
///
/// The positive control at the end proves the store CAN learn on this interface, so the
/// `learned.isEmpty` drop assertion is not vacuous.
@Test @MainActor func protectedPacketOnPlainInterfaceIsDropped() async {
    let (raw, _) = makeAnnouncePacket(hops: 2, emitted: 1000)
    // Flag-set-but-otherwise-valid: set bit 7 on the flags byte. The rest of the packet
    // (destination hash, signature, hops) is intact, so it parses and authenticates —
    // the only gate is the bit-7 check which identifies IFAC-flagged traffic.
    var flagged = raw
    flagged[0] |= 0x80
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), .default))   // no ifac
    await store.send(.received(InterfaceID("i0"), flagged))
    #expect(store.state.learned.isEmpty)          // nothing learned, under ANY key

    // Positive control: the SAME store on the SAME plain interface DOES admit an unprotected
    // packet. Without this the drop assertion above could pass vacuously.
    let (plainRaw, plainDest) = makeAnnouncePacket(hops: 2, emitted: 2000)
    await store.send(.received(InterfaceID("i0"), plainRaw))
    await store.receive(.delegate(.pathLearned(destinationHash: plainDest, hops: 2)))
    #expect(store.state.learned[plainDest] != nil)
}

// MARK: - #C5 C4 interaction regression

/// C4/C5 interaction regression: on an IFAC interface with an active ingress burst, a held
/// announce is stored MASKED (the verbatim `.received` payload) and, on release, re-enters
/// `.received` still masked so that it unmasks correctly a second time.
///
/// This is the specific failure that would result if IFAC unmasking lived upstream in an
/// Endpoint: the Endpoint would store de-masked bytes; on replay the IFAC flag check (bit-7
/// absent → drop) would silently discard the released announce. Reference RNS has exactly
/// this bug in process_held_announces. We are deliberately better.
@Test @MainActor func heldAnnounceOnIFACInterfaceIsReleasedAndAdmitted() async {
    let ifac = IFAC(networkName: "xnet", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.default
    profile.ifac = ifac

    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = profile
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    // Pre-arm an active burst that is past its penalty (heldRelease in the past, so the
    // first release attempt can proceed past the penalty gate).
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 900),
        heldRelease: Date(timeIntervalSince1970: 1000))
    // Seed one arrival so burst deactivation can evaluate the rate (needs > icDequeMinSample).
    initial.announceArrivals[i0] = [Date(timeIntervalSince1970: 998)]

    let (raw, destHash) = makeAnnouncePacket(hops: 1, emitted: 1000)
    // Store the MASKED bytes — this is what C4's hold always stores (verbatim .received payload).
    initial.heldAnnounces[i0] = [destHash: .init(raw: ifac.protect(raw), hops: 1)]

    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off

    // First release: burst is still active so it is held again (deactivates burst).
    now.setValue(Date(timeIntervalSince1970: 1001))
    await store.send(.heldAnnounceReleaseDue(i0))
    await store.receive { if case .received = $0 { return true }; return false }
    #expect(store.state.learned[destHash] == nil)            // bounced, burst deactivated
    #expect(store.state.ingressBursts[i0]?.active == false)

    // Second release: burst inactive, announce is admitted and path is learned.
    now.setValue(Date(timeIntervalSince1970: 1007))
    await store.send(.heldAnnounceReleaseDue(i0))
    await store.receive { if case .received = $0 { return true }; return false }
    #expect(store.state.learned[destHash] != nil)            // path learned — C5/C4 seam holds
}

// MARK: - #C5 IFAC registration ordering

/// IFAC registration ordering: a `.received` action arriving on an IFAC interface is
/// processed as IFAC-protected (not as plain-network traffic) even when the packet and the
/// `.interfaceConnected` are issued back-to-back in the same test turn.
///
/// This pins the safety property that "no registration ⇒ open network" (Transport.swift:248)
/// is unreachable in practice: TCA drains buffered actions FIFO, and `.interfaceConnected`
/// is always emitted exactly one hop before the first `.received` from the same interface,
/// so registration always precedes delivery. If that ordering were reversed, the IFAC-
/// protected packet would slip through as plain-network traffic and the path would be
/// learned from a masked packet with a garbled destination hash.
@Test @MainActor func ifacPacketArrivesAfterInterfaceConnectedIsIFACProcessed() async {
    let ifac = IFAC(networkName: "order-xval", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.default
    profile.ifac = ifac
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let masked = ifac.protect(raw)

    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    // Issue connect and receive in the production order: connect first, then a packet.
    // Both actions go through the reducer in FIFO order, so by the time `.received` is
    // handled, `state.interfaces[i0]` is already populated with the IFAC profile.
    await store.send(.interfaceConnected(InterfaceID("i0"), profile))
    await store.send(.received(InterfaceID("i0"), masked))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    // Path was learned — the packet was unmasked correctly, proving IFAC was in scope
    // when `.received` ran (not the "no registration ⇒ open" else branch).
    #expect(store.state.learned[destHash] != nil)
}

// MARK: - packet-dedup ring: production wiring, eviction, and cost

/// A PLAIN local destination and DATA packets addressed to it: delivery is observable and
/// `decrypt` is a passthrough, so thousands of packets can be driven through the reducer cheaply.
/// (Link-addressed packets are routed BEFORE the dedup guard — see `identicalLinkPacketsBypassDedup`
/// — so they cannot be used to exercise it.)
private func makePlainDataPacket(to dest: Destination, payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                destinationHash: dest.hash, transportId: nil, payload: payload).packed()
}

private func distinctPayload(_ i: Int) -> Data {
    var p = Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), UInt8((i >> 16) & 0xFF)])
    p.append(Data(repeating: 0xA5, count: 8))
    return p
}

/// The dedup ring the reducer ACTUALLY uses must be large enough that ordinary relay traffic
/// cannot flush a packet's own echo out of memory. Reference holds 500k-1M (RNS Transport.py:177);
/// we hold `Transport.seenPacketRingSize`. Driven through `.received` on the production
/// `Transport.State`, so reverting the wiring at Transport.swift:38 to the old 1000-entry default
/// fails this: packet #0 would be evicted and re-delivered.
@Test @MainActor func seenPacketRingRemembersFarMoreThanTheOldDefault() async {
    let dest = Destination(kind: .plain, direction: .in, appName: "app", aspects: ["ring"])!
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest))

    let first = makePlainDataPacket(to: dest, payload: distinctPayload(0))
    await store.send(.received(InterfaceID("i"), first))
    // 1100 further DISTINCT packets — more than the old 1000-entry default, so a ring that size
    // would have evicted `first` by the end of this loop.
    for i in 1...1100 {
        await store.send(.received(InterfaceID("i"), makePlainDataPacket(to: dest,
                                                                        payload: distinctPayload(i))))
    }
    // Nothing was evicted: all 1101 hashes are still held (production state, not a local ring).
    #expect(store.state.seenPacketHashes.count == 1101)

    // Drain the last delivery so the exhaustive flip below starts from an empty action queue.
    await store.receive { if case .delegate(.received) = $0 { return true }; return false }
    store.exhaustivity = .on
    // Replaying packet #0 must emit nothing at all — teardown catches a stray delivery.
    await store.send(.received(InterfaceID("i"), first))
}

/// The eviction path itself — the reason the ring is bounded, and the site of the old
/// `order.removeFirst()` O(ring) memmove. Exercised at a SMALL injected capacity, following
/// `blobRingEvictsOldestAfterCapacity`: filling 262144 entries through the reducer is not a test.
@Test @MainActor func seenPacketRingEvictsOldestAndReDeliversIt() async {
    let dest = Destination(kind: .plain, direction: .in, appName: "app", aspects: ["evict"])!
    var initial = Transport.State()
    initial.seenPacketHashes = RingSet(capacity: 2)
    let store = TestStore(initialState: initial) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest))

    let payloads = (0..<3).map { distinctPayload($0) }
    let packets = payloads.map { makePlainDataPacket(to: dest, payload: $0) }
    for (packet, payload) in zip(packets, payloads) {
        await store.send(.received(InterfaceID("i"), packet))
        await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: payload, packetHash: Packet(raw: packet)!.packetHash, interfaceID: InterfaceID("i"))))
    }
    #expect(store.state.seenPacketHashes.count == 2)     // bounded at the injected capacity

    // #0 was evicted by #2, so replaying it is delivered a SECOND time.
    await store.send(.received(InterfaceID("i"), packets[0]))
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: payloads[0], packetHash: Packet(raw: packets[0])!.packetHash, interfaceID: InterfaceID("i"))))
    // #2 is still remembered, so replaying it is suppressed. Flip exhaustivity LAST: teardown
    // catches a stray delivery.
    store.exhaustivity = .on
    await store.send(.received(InterfaceID("i"), packets[2]))
}

/// Cost characteristic, pinned rather than left to a comment. Pushing two full capacities through
/// a production-sized ring means every insert after the first `seenPacketRingSize` takes the
/// eviction path; the whole loop must finish in seconds, because `RingSet` is O(1) per insert
/// (circular buffer + boxed storage, no `removeFirst` memmove and no per-copy CoW).
// MARK: - rehydrateLearnedDestinations

/// A destination injected via `.rehydrateLearnedDestinations` is routable — `.send` routes
/// a packet to it — without waiting for an announce. This is the headline test for the slice.
/// The destination sits in `learned` and the interface is connected, so `reachableLearned`
/// returns the entry and routing succeeds.
@Test @MainActor func rehydratedDestinationIsReachableWithoutAnnounce() async {
    let remote = Identity()
    let ifID = InterfaceID("i0")
    let destHash = Destination.hash(
        identityHash: remote.hash, appName: "app", aspects: ["svc"])
    let learnedAt = Date(timeIntervalSince1970: 1_000)     // well within the 7-day window
    let entry = LearnedDestination(
        identity: remote, appData: nil, ratchet: nil, interfaceID: ifID,
        hops: 2, nextHop: destHash, announceEmitted: 500, learnedAt: learnedAt)

    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        // now = 2 days after learnedAt — fresh enough to survive the expiry sweep
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: learnedAt.timeIntervalSince1970 + 2 * 24 * 3600) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(ifID))
    await store.send(.rehydrateLearnedDestinations([destHash: entry]))

    // Destination is known; send must route a .transmit, not .sendFailed(.notLearned).
    await store.send(.send(destinationHash: destHash, plaintext: Data("hello".utf8)))
    await store.receive { action in
        if case .delegate(.transmit(ifID, _)) = action { return true }
        return false
    }
    store.exhaustivity = .on
}

/// A restored entry must NOT replace a live entry that is at least as fresh. The network can
/// populate `learned` before the async database read arrives; an unconditional write would move
/// `learnedAt` backwards and restore stale routing data.
@Test @MainActor func rehydrateDoesNotOverwriteFresherLiveEntry() async {
    let remote = Identity()
    let ifID = InterfaceID("i0")
    let destHash = Destination.hash(
        identityHash: remote.hash, appName: "app", aspects: ["svc"])
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let now   = Date(timeIntervalSince1970: 10_000)       // well within the 7-day window

    let liveEntry = LearnedDestination(
        identity: remote, appData: nil, ratchet: nil, interfaceID: ifID,
        hops: 1, nextHop: destHash, announceEmitted: 999, learnedAt: newer)
    let storedEntry = LearnedDestination(
        identity: remote, appData: nil, ratchet: nil, interfaceID: ifID,
        hops: 5, nextHop: destHash, announceEmitted: 100, learnedAt: older)

    var initial = Transport.State()
    initial.learned[destHash] = liveEntry    // live entry already in place

    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { now }
    }
    store.exhaustivity = .off
    await store.send(.rehydrateLearnedDestinations([destHash: storedEntry]))

    // The live entry (hops: 1, learnedAt: newer) must survive unchanged.
    #expect(store.state.learned[destHash]?.hops == 1)
    #expect(store.state.learned[destHash]?.learnedAt == newer)
    store.exhaustivity = .on
}

/// An entry whose `learnedAt` is older than `pathExpiry` (7 days) is NOT restored — it would
/// be swept by the next `maintenanceTick` anyway, and restoring it would briefly expose
/// stale routing data to senders.
@Test @MainActor func rehydrateDropsExpiredEntry() async {
    let remote = Identity()
    let ifID = InterfaceID("i0")
    let destHash = Destination.hash(
        identityHash: remote.hash, appName: "app", aspects: ["svc"])
    let learnedAt = Date(timeIntervalSince1970: 0)
    // now is one second past the expiry window (pathExpiry + 1 seconds after learnedAt).
    let now = Date(timeIntervalSince1970: Transport.pathExpiry + 1)
    let expired = LearnedDestination(
        identity: remote, appData: nil, ratchet: nil, interfaceID: ifID,
        hops: 2, nextHop: destHash, announceEmitted: 10, learnedAt: learnedAt)

    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { now }
    }
    store.exhaustivity = .off
    await store.send(.rehydrateLearnedDestinations([destHash: expired]))

    #expect(store.state.learned[destHash] == nil)
    store.exhaustivity = .on
}

/// An entry whose `learnedAt` is in the future is NOT restored. A future timestamp would
/// make the entry look unexpired indefinitely — it can never age past `pathExpiry` because its
/// distance from `now` only shrinks as time passes. `Date + TimeInterval` is Double arithmetic
/// and saturates rather than trapping, so there is no crash to catch; the test is the guard.
@Test @MainActor func rehydrateDropsFutureDatedEntry() async {
    let remote = Identity()
    let ifID = InterfaceID("i0")
    let destHash = Destination.hash(
        identityHash: remote.hash, appName: "app", aspects: ["svc"])
    let now = Date(timeIntervalSince1970: 1_000)
    // learnedAt is 1 second in the future relative to now.
    let future = Date(timeIntervalSince1970: 1_001)
    let futureDated = LearnedDestination(
        identity: remote, appData: nil, ratchet: nil, interfaceID: ifID,
        hops: 2, nextHop: destHash, announceEmitted: 10, learnedAt: future)

    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = DateGenerator { now }
    }
    store.exhaustivity = .off
    await store.send(.rehydrateLearnedDestinations([destHash: futureDated]))

    #expect(store.state.learned[destHash] == nil)
    store.exhaustivity = .on
}

// MARK: - Task F13 tests (relay link table hardening)

// A relayed entry is created UNVALIDATED, and junk data traffic must not validate it. (The hard
// proofDeadline reaping is verified by the next test, which controls the clock; this harness pins
// date to epoch, so it asserts only creation state and the no-validate-on-junk property.)
@Test @MainActor func relayedLinkRequestCreatesUnvalidatedEntryAndJunkDoesNotValidateIt() async {
    let (store, relay, destHash, _) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    await store.send(.received(InterfaceID("in"), lr))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID] != nil)
    #expect(store.state.linkTable[linkID]?.validated == false, "a relayed entry starts unvalidated")
    // A junk data packet for the link must not flip validated (only an LRPROOF may).
    let junk = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([9, 9, 9]))
    await store.send(.received(InterfaceID("in"), junk))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID]?.validated == false, "junk data must not validate an entry")
    await store.finish()
}

@Test @MainActor func maintenanceReapsUnvalidatedByDeadlineAndKeepsValidatedByRefresh() async {
    // Two entries in a controllable-clock store: one unvalidated past its deadline (reaped),
    // one validated and freshly refreshed (kept).
    let now = Date(timeIntervalSince1970: 100_000)
    var initial = Transport.State()
    initial.interfaces = [InterfaceID("a"): .default, InterfaceID("b"): .default]
    let staleUnvalidated = Data(repeating: 0x01, count: 16)
    let freshValidated = Data(repeating: 0x02, count: 16)
    initial.linkTable[staleUnvalidated] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID("a"), nhIf: InterfaceID("b"),
        refreshedAt: now, validated: false,
        proofDeadline: Date(timeIntervalSince1970: 99_000))          // already past
    initial.linkTable[freshValidated] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID("a"), nhIf: InterfaceID("b"),
        refreshedAt: now, validated: true,
        proofDeadline: Date(timeIntervalSince1970: 0))               // ignored for validated
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = .constant(now)
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.maintenanceTick)
    #expect(store.state.linkTable[staleUnvalidated] == nil, "unvalidated past deadline is reaped")
    #expect(store.state.linkTable[freshValidated] != nil, "validated + fresh survives")
    await store.finish()
}

@Test @MainActor func lrproofValidatesEntryWithoutRefreshingAndDataRefreshes() async {
    // Forwarding an LRPROOF marks the entry validated but does NOT bump refreshedAt; a data
    // packet DOES bump refreshedAt.
    let seededAt = Date(timeIntervalSince1970: 0)
    var initial = Transport.State()
    initial.interfaces = [InterfaceID("ar"): .default, InterfaceID("rb"): .default]
    let linkID = Data(repeating: 0xEE, count: 16)
    initial.linkTable[linkID] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID("ar"), nhIf: InterfaceID("rb"),
        refreshedAt: seededAt, validated: false,
        proofDeadline: Date(timeIntervalSince1970: 1_000_000))
    let now = Date(timeIntervalSince1970: 500)
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = .constant(now)
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    // Forward an LRPROOF (packetType .proof, context .linkRequestProof) for the link.
    let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                       destinationType: .link, context: .linkRequestProof, contextFlag: false, hops: 0,
                       destinationHash: linkID, transportId: nil, payload: Data(repeating: 0x1, count: 96))
    await store.send(.received(InterfaceID("ar"), try! proof.packed()))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID]?.validated == true, "LRPROOF validates the entry")
    #expect(store.state.linkTable[linkID]?.refreshedAt == seededAt, "LRPROOF must not refresh")
    // Now a data packet refreshes.
    let data = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([1, 2, 3]))
    await store.send(.received(InterfaceID("ar"), data))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID]?.refreshedAt == now, "a data packet refreshes")
    await store.finish()
}

///
/// For scale: the value-typed `RingSet` this replaced cost 67-82 ms per insert at this capacity
/// under TCA's per-action `State` copy — this loop would have taken ~10 hours.
@Test func ringSetInsertIsConstantTimeAtLargeCapacity() {
    var ring = RingSet(capacity: Transport.seenPacketRingSize)
    var item = Data(repeating: 0x5A, count: 32)
    let started = Date()
    for i in 0..<(2 * Transport.seenPacketRingSize) {
        item.withUnsafeMutableBytes { $0.storeBytes(of: UInt64(i), toByteOffset: 0, as: UInt64.self) }
        _ = ring.insert(item)
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(ring.count == Transport.seenPacketRingSize)   // bounded: never grows past capacity
    #expect(elapsed < 30)                                 // generous even for a debug build
}
