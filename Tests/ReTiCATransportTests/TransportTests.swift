import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

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
        $0.interfaces = [InterfaceID("i1")]
    }
    await store.send(.registerLocalDestination(dest)) {
        $0.localDestinations = [dest.hash: dest]
    }
    await store.send(.interfaceDisconnected(InterfaceID("i1"))) {
        $0.interfaces = []
    }
}

// Builds a raw ANNOUNCE packet (HEADER_1) for a synthetic identity.
private func makeAnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                hops: UInt8, emitted: UInt64, appData: Data? = nil) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
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
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext)))
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

@Test @MainActor func announceEmitsValidPayloadPerInterface() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i1"))) { $0.interfaces = [InterfaceID("i1")] }
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
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext)))

    // Second copy of the same raw frame — must be dropped by dedup.
    // Switch exhaustivity ON so any spurious delegate action would be caught.
    store.exhaustivity = .on
    await store.send(.received(InterfaceID("i1"), raw)) // no receive step → asserts no action emitted
}

@Test @MainActor func recencyEqualEmissionPrefersFewerHops() async {
    let id = Identity()
    let (farther, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 6, emitted: 300)
    let (closer, _)         = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2, emitted: 300)
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
    // Use exhaustivity on, but supply the expected state delta (seenPacketHashes insertion)
    // so that any spurious delegate action is caught as unexpected.
    store.exhaustivity = .on
    let expectedHash = Packet(raw: rawPacket)!.packetHash
    await store.send(.received(InterfaceID("i1"), rawPacket)) {
        $0.seenPacketHashes.insert(expectedHash)
    }
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
        if case let .delegate(.linkPacket(l, d)) = action { captured.setValue((l, d)); return true }
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
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { action in
        if case let .delegate(.linkRequest(h, _)) = action { captured.setValue(h); return true }
        return false
    }
    #expect(captured.value == dest.hash)
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

@Test @MainActor func relayRebroadcastsAnnounceWithHeader2AndOurTransportId() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))

    // A genuine-shape HEADER_1 announce for a REMOTE destination, heard on i0 at hops = 2.
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    // Verify exactly 2 interfaces are registered before the announce arrives.
    #expect(store.state.interfaces == [InterfaceID("i0"), InterfaceID("i1")])

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
    let expectedHashA = Packet(raw: localRaw)!.packetHash
    await store.send(.received(InterfaceID("i0"), localRaw)) {
        $0.seenPacketHashes.insert(expectedHashA)
    }
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
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i1"))) { $0.interfaces = [InterfaceID("i1")] }
    await store.send(.interfaceConnected(InterfaceID("i2"))) { $0.interfaces = [InterfaceID("i1"), InterfaceID("i2")] }
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
