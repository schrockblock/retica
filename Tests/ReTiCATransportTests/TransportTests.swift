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
    storeA.exhaustivity = .on
    let expectedHashA = Packet(raw: inboundA)!.packetHash
    await storeA.send(.received(InterfaceID("i0"), inboundA)) {
        $0.seenPacketHashes.insert(expectedHashA)
    }

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
    let expectedHashB = Packet(raw: inboundB)!.packetHash
    await storeB.send(.received(InterfaceID("i0"), inboundB)) {
        $0.seenPacketHashes.insert(expectedHashB)
    }
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
    let expectedHashC = Packet(raw: inboundC)!.packetHash
    await storeC.send(.received(InterfaceID("i0"), inboundC)) {
        $0.seenPacketHashes.insert(expectedHashC)
    }
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
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext)))
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
    await storeB.receive(.delegate(.received(destinationHash: destB.hash, plaintext: plaintext)))
}
