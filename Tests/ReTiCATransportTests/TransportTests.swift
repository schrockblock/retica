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
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
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

// MARK: - #4c-2 announce cache

/// Learning a path caches the announce payload verbatim (for later relay path-responses).
@Test @MainActor func learningPathCachesAnnouncePayload() async {
    let (raw, destHash) = makeAnnouncePacket(hops: 2)
    let expectedPayload = Packet(raw: raw)!.payload
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceCache[destHash] == expectedPayload)
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
    await storeB.receive(.delegate(.received(destinationHash: destB.hash, plaintext: plaintext)))
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
    initialState.interfaces = [InterfaceID(rcvdIf), InterfaceID(nhIf)]
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
        if case let .delegate(.linkPacket(l, d)) = action { captured.setValue((l, d)); return true }
        return false
    }
    #expect(captured.value?.0 == unknownLinkID)
    #expect(captured.value?.1 == lp)
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
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext)))
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

/// A relay with two interfaces and a controllable clock/jitter.
@MainActor
private func makeTimedRelayStore(_ relay: Identity, _ clock: TestClock<Duration>, jitterByte: UInt8)
    async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.randomBytes = RandomBytesGenerator { _ in Data([jitterByte]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
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

/// The jitter formula maps a random byte to `byte/256` of the window, always within `[0, window)`.
/// Pins the exact delay value directly (the clock/async tests can only observe that *a* delay
/// elapsed, not the precise fraction).
@Test func announceJitterMapsByteToWindowFraction() {
    #expect(Transport.announceJitter(0) == 0.0)
    #expect(Transport.announceJitter(128) == 0.25)                                  // 128/256 * 0.5
    #expect(Transport.announceJitter(255) == Double(255) / 256.0 * 0.5)
    #expect(Transport.announceJitter(255) < Transport.announceRebroadcastWindow)    // strictly inside
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

/// A duplicate tagged request is ignored; a fresh tag is answered again (RNS discovery_pr_tags,
/// Transport.py:2924-2934). Exercised on the owner-answer path.
@Test @MainActor func duplicateTaggedPathRequestIsIgnored() async {
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

    // Fresh tag A → answered.
    let first = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tagA)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { first.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: first.value!)?.context == .pathResponse)

    // Same tag A again → ignored (no transmit).
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tagA)))

    // Different tag B → answered again.
    let third = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tagB)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { third.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: third.value!)?.context == .pathResponse)
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
