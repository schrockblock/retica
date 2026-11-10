import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// The AutoInterface reducer against a mock driver and a `TestClock` (spec 2026-11-10-autointerface
/// §5.4, §7.2 items 1-9). Reference: RNS 1.6.0 `Interfaces/AutoInterface.py` (`AI`).
@MainActor @Suite struct AutoInterfaceReducerTests {

    // MARK: §7.2.1 eligibility

    @Test func startBindsEligibleNICsInEnumerationOrderWithTheLastDescopedLinkLocal() async {
        let nics = [
            AutoNIC(name: "lo0", index: 1, linkLocals: ["fe80::1"]),
            AutoNIC(name: "awdl0", index: 9, linkLocals: ["fe80::9"]),
            AutoNIC(name: "en5", index: 10, linkLocals: ["fe80::10"]),
            AutoNIC(name: "utun3", index: 11, linkLocals: ["fe80::11"]),
            AutoNIC(name: "pdp_ip0", index: 12, linkLocals: ["fe80::12"]),
            AutoNIC(name: "en2", index: 6, linkLocals: ["fe80::a", "fe80:6::b"]),   // last, descoped
            AutoNIC(name: "en1", index: 5, linkLocals: ["fe80::2"]),                // ignored_devices
            AutoNIC(name: "bridge100", index: 13, linkLocals: []),                  // no address
            autoEn0,
        ]
        let config = AutoInterfaceConfig(ignoredDevices: ["en1"])
        let h = AutoHarness(nics: nics, config: config)
        await h.store.send(.start)
        await h.settle()
        #expect(h.calls.value.first == .run([autoBinding("en2", 6, "fe80::b"), autoBinding("en0", 4, "fe80::1")]))
        #expect(Set(h.store.state.nics.keys) == ["en2", "en0"])
        #expect(h.store.state.nics["en2"]?.linkLocal == "fe80::b")
        await h.finish()
    }

    @Test func lo0StaysSkippedWhenListedInDevicesButTheDarwinIgnoreListDoesNot() async {
        let nics = [AutoNIC(name: "lo0", index: 1, linkLocals: ["fe80::1"]),
                    AutoNIC(name: "awdl0", index: 9, linkLocals: ["fe80::9"]),
                    AutoNIC(name: "utun3", index: 11, linkLocals: ["fe80::11"]),
                    autoEn0, autoEn1]
        let config = AutoInterfaceConfig(scope: .site, discoveryPort: 2000, dataPort: 3000,
                                         devices: ["lo0", "awdl0", "utun3", "en0"])
        let h = AutoHarness(nics: nics, config: config)
        await h.store.send(.start)
        await h.settle()
        #expect(h.calls.value.first == .run([
            autoBinding("awdl0", 9, "fe80::9", config: config),
            autoBinding("utun3", 11, "fe80::11", config: config),
            autoBinding("en0", 4, "fe80::1", config: config),
        ]))
        if case let .run(b) = h.calls.value.first { #expect(b.allSatisfy { !$0.linkScope && $0.group[1] == 0x15 }) }
        await h.finish()
    }

    // MARK: §7.2.2 announces

    @Test func announcesAtZeroAndEvery1_6SecondsPerNICWithTheExactToken() async {
        let h = AutoHarness()
        await h.store.send(.start)
        await h.settle()
        // Spec §4.2 vector: SHA-256(b"reticulum" + b"fe80::1").
        let en0Token = Data(hex: "97b25576749ea936b0d8a8536ffaf442d157cf47d460dcf13c48b7bd18b6c163")
        let round: [AutoCall] = [.multicast(nic: "en0", token: en0Token, port: 29716),
                                 .multicast(nic: "en1", token: autoToken("fe80::2"), port: 29716)]
        #expect(h.multicasts == round, "the first announce goes out at t = 0")
        await h.advance(to: 1.5)
        #expect(h.multicasts.count == 2)
        await h.advance(to: 1.6)
        #expect(h.multicasts == round + round)
        await h.advance(to: 4.7)
        #expect(h.multicasts == round + round + round)
        await h.finish()
    }

    // MARK: §7.2.3 inbound discovery

    @Test func discoveryAndEchoesBefore1_92SecondsAreDropped() async {
        let h = AutoHarness()
        await h.store.send(.start)
        await h.advance(to: 1.9)
        #expect(!h.store.state.accepting)
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.discovery(autoEn0, from: "fe80::1")
        #expect(h.store.state.peers.isEmpty)
        #expect(h.store.state.nics["en0"]?.firstEcho == nil)
        await h.advance(to: 1.92)
        #expect(h.store.state.accepting)
        #expect(h.store.state.status == .running)
        await h.discovery(autoEn0, from: "fe80::aa")
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0")])
        await h.finish()
    }

    @Test func validTokenAddsOnePeerRepeatsOnlyRefreshAndBadTokensAreDropped() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.advance(to: 2)
        await h.discovery(autoEn0, from: "fe80::aa")
        #expect(h.store.state.peers["fe80::aa"] == AutoInterface.Peer(nic: "en0", index: 4, lastHeard: h.at(2), lastOutbound: h.at(2)))
        await h.advance(to: 3)
        // Heard again on the other NIC and the other plane: refresh only, the first NIC stays.
        await h.discovery(autoEn1, from: "fe80::aa", plane: .unicastDiscovery)
        #expect(h.store.state.peers["fe80::aa"] == AutoInterface.Peer(nic: "en0", index: 4, lastHeard: h.at(3), lastOutbound: h.at(2)))
        await h.discovery(autoEn0, from: "fe80::bb", payload: autoToken("fe80::cc"))                     // bad hash
        await h.discovery(autoEn0, from: "fe80::bb", payload: autoToken("fe80::bb").prefix(31))          // short
        await h.discovery(autoEn0, from: "fe80::bb", payload: autoToken("fe80::bb", group: Data("othergroup".utf8)))
        await h.discovery(autoEn0, from: "fe80::bb", payload: Data())
        #expect(h.store.state.peers["fe80::bb"] == nil)
        await h.discovery(autoEn1, from: "fe80::bb", payload: autoToken("fe80::bb") + Data([1, 2, 3]))   // trailing bytes
        #expect(h.store.state.peers["fe80::bb"]?.nic == "en1")
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0"), .peerAdded(addr: "fe80::bb", nic: "en1")])
        await h.finish()
    }

    @Test func aSourceScopeMatchingNoNICIsDroppedAndThePeerCapHolds() async {
        let h = AutoHarness(config: AutoInterfaceConfig(peerCap: 1))
        await h.startAndAccept()
        await h.discovery(autoEn0, from: "fe80::aa", scope: 99)
        #expect(h.store.state.peers.isEmpty)
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.discovery(autoEn0, from: "fe80::bb")
        #expect(Array(h.store.state.peers.keys) == ["fe80::aa"])
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0")])
        await h.finish()
    }

    @Test func theSourceIsDescopedBeforeTheTokenCheck() async {
        let h = AutoHarness()
        await h.startAndAccept()
        // An embedded-scope source (`fe80:4::aa`) hashes as `fe80::aa`, the sender's own text (§4.3).
        await h.discovery(autoEn0, from: "fe80:4::aa", payload: autoToken("fe80::aa"))
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0")])
        await h.finish()
    }

    // MARK: Review Focus 1 / §7.2.4 echoes

    @Test func ourOwnEchoNeverCreatesAPeerEvenOnAnotherNICOrFromASecondAddress() async {
        let en2 = AutoNIC(name: "en2", index: 6, linkLocals: ["fe80::a", "fe80::b", "fe80::c"])   // adopts fe80::c
        let h = AutoHarness(nics: [autoEn0, autoEn1, en2])
        await h.startAndAccept()
        await h.advance(to: 2)
        await h.discovery(autoEn0, from: "fe80::1")
        #expect(h.store.state.nics["en0"]?.firstEcho == h.at(2))
        await h.advance(to: 3)
        // en0's echo arriving on en1 (the other NIC's socket and scope): it is en0's echo.
        await h.discovery(autoEn1, from: "fe80::1")
        #expect(h.store.state.nics["en0"]?.lastEcho == h.at(3))
        #expect(h.store.state.nics["en0"]?.firstEcho == h.at(2))
        #expect(h.store.state.nics["en1"]?.firstEcho == nil)
        // A NIC's non-adopted fe80 address (spec R6: the kernel may source multicast from it):
        // ours, so never a peer.
        await h.discovery(en2, from: "fe80::b")
        // Our address with someone else's token: dropped, and not an echo either.
        await h.discovery(autoEn1, from: "fe80::2", payload: autoToken("fe80::aa"))
        #expect(h.store.state.nics["en1"]?.firstEcho == nil)
        #expect(h.store.state.peers.isEmpty)
        #expect(h.delegates.value.isEmpty)
        await h.finish()
    }

    @Test func watchdogReportsLostAtTheSecondTickUnavailableOnceAndRecoveredAfterAnEcho() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.advance(to: 3)
        await h.discovery(autoEn0, from: "fe80::1")         // en0 echoes once, at 3
        await h.advance(to: 4)
        #expect(h.delegates.value.isEmpty, "the first evaluation sets state silently")
        await h.advance(to: 8)
        #expect(h.delegates.value == [.carrierLost(nic: "en1"), .multicastUnavailable(nic: "en1")])
        await h.advance(to: 12)
        // en0 last echoed at 3: lost at 12, but it has echoed, so it is not "unavailable".
        #expect(h.delegates.value == [.carrierLost(nic: "en1"), .multicastUnavailable(nic: "en1"), .carrierLost(nic: "en0")])
        await h.advance(to: 13)
        await h.discovery(autoEn1, from: "fe80::2")
        await h.advance(to: 16)
        #expect(h.delegates.value == [.carrierLost(nic: "en1"), .multicastUnavailable(nic: "en1"), .carrierLost(nic: "en0"),
                                      .carrierRecovered(nic: "en1")])
        await h.advance(to: 24)
        // en1 last echoed at 13: lost again at 20. Its echo means no second "unavailable".
        #expect(h.delegates.value == [.carrierLost(nic: "en1"), .multicastUnavailable(nic: "en1"), .carrierLost(nic: "en0"),
                                      .carrierRecovered(nic: "en1"), .carrierLost(nic: "en1")])
        await h.finish()
    }

    // MARK: §7.2.5 eviction, Review Focus 2

    @Test func aPeerIsEvictedAtTheFirstTickPast22SecondsAndDataKeepsItAlive() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.advance(to: 2.5)
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.discovery(autoEn1, from: "fe80::bb")
        await h.advance(to: 20)
        await h.data(autoEn1, from: "fe80::bb", blob("keepalive"))
        await h.advance(to: 24)
        #expect(Set(h.store.state.peers.keys) == ["fe80::aa", "fe80::bb"], "24 is not past 2.5 + 22")
        await h.advance(to: 28)
        #expect(Set(h.store.state.peers.keys) == ["fe80::bb"])
        #expect(h.delegates.value.contains(.peerRemoved(addr: "fe80::aa")))
        await h.advance(to: 40)
        #expect(h.store.state.peers["fe80::bb"] != nil)
        await h.advance(to: 44)
        #expect(h.store.state.peers.isEmpty)
        #expect(h.delegates.value.filter { if case .peerRemoved = $0 { true } else { false } }
                == [.peerRemoved(addr: "fe80::aa"), .peerRemoved(addr: "fe80::bb")])
        await h.finish()
    }

    @Test func aDedupedDatagramDoesNotRefreshItsPeer() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.advance(to: 2.5)
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.discovery(autoEn1, from: "fe80::ab")
        await h.advance(to: 20)
        let p = blob("broadcast")
        await h.data(autoEn1, from: "fe80::ab", p)
        await h.advance(to: 20.5)
        await h.data(autoEn0, from: "fe80::aa", p)       // the same packet via the remote's other NIC
        #expect(h.store.state.peers["fe80::aa"]?.lastHeard == h.at(2.5))
        #expect(h.delegates.value.filter { if case .packetReceived = $0 { true } else { false } }
                == [.packetReceived(addr: "fe80::ab", data: p)])
        await h.advance(to: 28)
        #expect(Array(h.store.state.peers.keys) == ["fe80::ab"])
        await h.finish()
    }

    // MARK: §7.2.6 reverse announce

    @Test func reverseAnnounceAtTheFirstTickPast5_2SecondsCarriesOurTokenForThePeersNIC() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.advance(to: 2.5)
        await h.discovery(autoEn1, from: "fe80::aa")
        let reverse = AutoCall.unicast(addr: "fe80::aa", index: 5, port: 29717, datagram: autoToken("fe80::2"))
        await h.advance(to: 4)
        #expect(h.unicasts.isEmpty)
        await h.advance(to: 8)
        #expect(h.unicasts == [reverse])
        await h.advance(to: 12)
        #expect(h.unicasts == [reverse], "12 is not past 8 + 5.2")
        await h.advance(to: 16)
        #expect(h.unicasts == [reverse, reverse])
        await h.finish()
    }

    // MARK: §7.2.7 data plane

    @Test func dataFromAnUnknownAddressAndOversizeDataAreDropped() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.data(autoEn0, from: "fe80::cc", blob("x"))
        await h.data(autoEn0, from: "fe80::aa", blob("big", 1213))
        await h.data(autoEn0, from: "fe80::aa", Data())
        let max = blob("max", 1212)     // HW_MTU 1196 + IFAC 16 (TP:2017-2018)
        await h.data(autoEn0, from: "fe80::aa", max)
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0"), .packetReceived(addr: "fe80::aa", data: max)])
        await h.finish()
    }

    @Test func dedupeWindowIs0_75SecondsAndTheRingEvictsAt49Entries() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.advance(to: 2)
        await h.discovery(autoEn0, from: "fe80::aa")
        let p = blob("p")
        func received() -> [Data] {
            h.delegates.value.compactMap { if case let .packetReceived(_, d) = $0 { d } else { nil } }
        }
        await h.advance(to: 3)
        await h.data(autoEn0, from: "fe80::aa", p)
        await h.advance(to: 3.5)
        await h.data(autoEn0, from: "fe80::aa", p)        // hit
        await h.advance(to: 3.75)
        await h.data(autoEn0, from: "fe80::aa", p)        // 3 + 0.75: miss (strict <, AI:658)
        #expect(received() == [p, p])
        await h.advance(to: 5)
        let q = (0..<49).map { blob("q\($0)") }
        for i in 0..<48 { await h.data(autoEn0, from: "fe80::aa", q[i]) }
        await h.data(autoEn0, from: "fe80::aa", q[0])     // 48 entries: still held, hit
        #expect(received().count == 2 + 48)
        await h.data(autoEn0, from: "fe80::aa", q[48])    // the 49th evicts q0
        await h.data(autoEn0, from: "fe80::aa", q[0])
        #expect(received() == [p, p] + q[0..<48] + [q[48], q[0]])
        await h.finish()
    }

    // MARK: §7.2.6 send

    @Test func sendGoesToThePeersNICOnTheDataPortAndUnknownAddressesAreDropped() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.discovery(autoEn1, from: "fe80::aa")
        await h.store.send(.send(addr: "fe80::aa", data: blob("out")))
        await h.store.send(.send(addr: "fe80::zz", data: blob("nowhere")))
        await h.settle()
        #expect(h.unicasts == [.unicast(addr: "fe80::aa", index: 5, port: 42671, datagram: blob("out"))])
        await h.finish()
    }

    // MARK: §7.2.8 address change, D1-D3, R11

    @Test func anAddressChangeRebindsUsesTheNewTokenAndKeepsTheExistingPeer() async {
        let h = AutoHarness()
        await h.startAndAccept()
        await h.discovery(autoEn0, from: "fe80::aa")
        h.nics.setValue([AutoNIC(name: "en0", index: 4, linkLocals: ["fe80::9"]), autoEn1])
        await h.advance(to: 4)
        #expect(h.rebinds == [.rebind(autoBinding("en0", 4, "fe80::9"))])
        let before = h.multicasts.count
        await h.advance(to: 4.85)   // the third 1.6 s sleep ends a few attoseconds past 4.8
        #expect(Array(h.multicasts.dropFirst(before)) == [.multicast(nic: "en0", token: autoToken("fe80::9"), port: 29716),
                                                          .multicast(nic: "en1", token: autoToken("fe80::2"), port: 29716)])
        await h.store.send(.send(addr: "fe80::aa", data: blob("still")))
        await h.settle()
        #expect(h.unicasts.last == .unicast(addr: "fe80::aa", index: 4, port: 42671, datagram: blob("still")))
        // The old address's late echo is still ours.
        await h.discovery(autoEn0, from: "fe80::1")
        #expect(Array(h.store.state.peers.keys) == ["fe80::aa"])
        await h.advance(to: 8)
        #expect(h.rebinds.count == 1, "an unchanged address is not rebound again")
        await h.finish()
    }

    @Test func aVanishedNICIsUnboundWithItsPeersEvictedAndANewOneIsAdopted() async {
        let h = AutoHarness(nics: [])
        await h.store.send(.start)
        await h.settle()
        #expect(h.calls.value.first == .run([]))
        #expect(h.store.state.status == .noUsableInterfaces)
        #expect(h.delegates.value == [.noUsableInterfaces])
        h.nics.setValue([autoEn0])
        await h.advance(to: 4)
        #expect(h.rebinds == [.rebind(autoBinding("en0", 4, "fe80::1"))])
        #expect(h.store.state.status == .running)
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.advance(to: 4.85)
        #expect(h.multicasts.last == .multicast(nic: "en0", token: autoToken("fe80::1"), port: 29716))
        h.nics.setValue([])
        await h.advance(to: 8)
        #expect(h.calls.value.contains(.unbind("en0")))
        #expect(h.store.state.peers.isEmpty)
        #expect(h.store.state.status == .noUsableInterfaces)
        #expect(h.delegates.value == [.noUsableInterfaces, .peerAdded(addr: "fe80::aa", nic: "en0"),
                                      .peerRemoved(addr: "fe80::aa"), .noUsableInterfaces])
        await h.finish()
    }

    @Test func aDataPortClashSurfacesOnlyDataPortInUseRetriesEveryTickAndTheWatchdogResumesOnceBound() async {
        let h = AutoHarness()
        await h.store.send(.start)
        await h.settle()
        let clash = AutoSocketEvent.bindFailed(nic: "en0", plane: .data, errno: EADDRINUSE)
        await h.store.send(.socketEvent(clash))
        await h.store.send(.socketEvent(.bound(nic: "en1")))
        await h.advance(to: 1.6)
        #expect(h.multicasts.suffix(1) == [.multicast(nic: "en1", token: autoToken("fe80::2"), port: 29716)],
                "en0 does not announce while its data plane is down")
        // The clash persists: every retry fails again. Three ticks, past the 6.5 s echo timeout.
        for (i, t) in [4.0, 8.0, 12.0].enumerated() {
            await h.advance(to: t)
            #expect(h.rebinds.count == i + 1, "retried at \(t)")
            await h.store.send(.socketEvent(clash))
        }
        #expect(h.delegates.value.filter { nicOf($0) == "en0" } == [.dataPortInUse(nic: "en0")],
                "a down NIC reports only the clash, never carrierLost / multicastUnavailable")
        #expect(h.delegates.value.contains(.carrierLost(nic: "en1")), "the healthy NIC is still watched")
        // The clash clears on the next retry.
        await h.advance(to: 12.5)
        await h.store.send(.socketEvent(.bound(nic: "en0")))
        await h.advance(to: 14.5)
        #expect(h.multicasts.suffix(2) == [.multicast(nic: "en0", token: autoToken("fe80::1"), port: 29716),
                                           .multicast(nic: "en1", token: autoToken("fe80::2"), port: 29716)])
        await h.advance(to: 16)
        #expect(h.rebinds.count == 3, "no retry once bound")
        #expect(h.delegates.value.filter { nicOf($0) == "en0" } == [.dataPortInUse(nic: "en0")],
                "the echo clock restarted at the bind (12.5): 16 is the silent first pass")
        await h.advance(to: 20)
        #expect(h.delegates.value.filter { nicOf($0) == "en0" }
                == [.dataPortInUse(nic: "en0"), .carrierLost(nic: "en0"), .multicastUnavailable(nic: "en0")])
        await h.finish()
    }

    @Test func aDownNICIsNoEvidenceOfLocalNetworkDenial() async {
        let h = AutoHarness(nics: [autoEn0])
        h.unicastResult.setValue(.failed(errno: EHOSTUNREACH))
        await h.startAndAccept()
        await h.store.send(.socketEvent(.bound(nic: "en0")))
        await h.discovery(autoEn0, from: "fe80::aa")
        await h.advance(to: 2)
        await h.store.send(.socketEvent(.readFailed(nic: "en0", plane: .data, errno: EBADF)))
        await h.store.send(.send(addr: "fe80::aa", data: blob("denied")))      // fails EHOSTUNREACH
        await h.advance(to: 12)
        #expect(h.unicasts.count >= 1)
        #expect(!h.delegates.value.contains(.localNetworkDenied), "only a down NIC is silent")
        #expect(!h.delegates.value.contains(.carrierLost(nic: "en0")))
        await h.advance(to: 12.5)
        await h.store.send(.socketEvent(.bound(nic: "en0")))
        await h.advance(to: 20)
        #expect(h.delegates.value.filter { $0 == .localNetworkDenied }.count == 1,
                "once the NIC is up and still hears no echo, the earlier denied send counts")
        await h.finish()
    }

    @Test func aJoinThatFailsOnALaterRebindIsRetriedNotSkipped() async {
        let h = AutoHarness()
        await h.store.send(.start)
        await h.settle()
        await h.store.send(.socketEvent(.bound(nic: "en0")))
        await h.store.send(.socketEvent(.bound(nic: "en1")))
        h.nics.setValue([AutoNIC(name: "en0", index: 4, linkLocals: ["fe80::9"]), autoEn1])
        await h.advance(to: 4)
        #expect(h.rebinds == [.rebind(autoBinding("en0", 4, "fe80::9"))])
        // A transient join failure during the address change.
        await h.store.send(.socketEvent(.bindFailed(nic: "en0", plane: .multicastDiscovery, errno: EADDRNOTAVAIL)))
        await h.settle()
        #expect(!h.calls.value.contains(.unbind("en0")))
        #expect(h.store.state.nics["en0"]?.failed == [.multicastDiscovery])
        #expect(!h.delegates.value.contains(.multicastUnavailable(nic: "en0")))
        await h.advance(to: 8)
        #expect(h.rebinds == [.rebind(autoBinding("en0", 4, "fe80::9")), .rebind(autoBinding("en0", 4, "fe80::9"))])
        await h.store.send(.socketEvent(.bound(nic: "en0")))
        let before = h.multicasts.count
        await h.advance(to: 9.65)
        #expect(Array(h.multicasts.dropFirst(before)).first == .multicast(nic: "en0", token: autoToken("fe80::9"), port: 29716))
        await h.finish()
    }

    @Test func aDeniedSendFromAStoppedSessionDoesNotMarkTheNextOne() async {
        let h = AutoHarness()
        h.holdFirstSessionMulticast.setValue(true)     // session 1's announce returns EHOSTUNREACH, late
        await h.store.send(.start)
        await h.settle()
        #expect(h.multicasts.first == .multicast(nic: "en0", token: autoToken("fe80::1"), port: 29716))
        await h.store.send(.stop)
        for _ in 0..<200 where !h.store.state.isIdle { await h.settle() }
        await h.store.send(.start)                      // session 2: every send succeeds
        await h.settle()
        h.holdFirstSessionMulticast.setValue(false)     // the stale failure arrives now
        await h.settle()
        await h.advance(to: 12)
        #expect(!h.delegates.value.contains(.localNetworkDenied), "\(h.delegates.value)")
        await h.finish()
    }

    @Test func aFailedMulticastJoinSkipsTheNICForTheSession() async {
        let h = AutoHarness()
        await h.store.send(.start)
        await h.settle()
        await h.store.send(.socketEvent(.bindFailed(nic: "en0", plane: .multicastDiscovery, errno: EADDRNOTAVAIL)))
        await h.settle()
        #expect(h.calls.value.contains(.unbind("en0")))
        #expect(h.store.state.nics["en0"] == nil)
        #expect(h.delegates.value == [.multicastUnavailable(nic: "en0")])
        await h.advance(to: 4)
        #expect(h.rebinds.isEmpty, "not re-adopted while it is still present")
        await h.finish()
    }

    // MARK: §8.4 local network denied

    @Test func localNetworkDeniedIsEmittedOnceAfterDeniedSendsAndNoEcho() async {
        let h = AutoHarness()
        h.multicastResult.setValue(.failed(errno: EHOSTUNREACH))
        await h.store.send(.start)
        await h.advance(to: 4)
        #expect(!h.delegates.value.contains(.localNetworkDenied), "not before 6.5 s without an echo")
        await h.advance(to: 8)
        await h.advance(to: 16)
        #expect(h.delegates.value.filter { $0 == .localNetworkDenied }.count == 1)
        await h.finish()
    }

    @Test func localNetworkDeniedNeedsADeniedErrnoAndNoEcho() async {
        let a = AutoHarness()
        a.multicastResult.setValue(.failed(errno: ENXIO))
        await a.store.send(.start)
        await a.advance(to: 12)
        #expect(!a.delegates.value.contains(.localNetworkDenied))
        await a.finish()

        let b = AutoHarness()
        b.multicastResult.setValue(.failed(errno: EPERM))
        await b.startAndAccept()
        await b.discovery(autoEn0, from: "fe80::1")
        await b.advance(to: 12)
        #expect(!b.delegates.value.contains(.localNetworkDenied))
        await b.finish()
    }

    // MARK: §7.2.9 / Review Focus 3 stop

    @Test func afterStopLateSocketEventsAndTicksSurfaceNothing() async throws {
        let h = AutoHarness()
        await h.startAndAccept()
        let session = try #require(h.sessions.value.first)
        session.yield(.datagram(nic: "en0", plane: .multicastDiscovery, source: "fe80::aa", sourceScope: 4, payload: autoToken("fe80::aa")))
        for _ in 0..<200 where h.store.state.peers.isEmpty { await Task.megaYield() }
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0")], "the stream reaches the reducer")
        await h.store.send(.stop)
        await h.settle()
        #expect(h.calls.value.last == .stop)
        #expect(h.store.state.peers.isEmpty && h.store.state.nics.isEmpty && !h.store.state.accepting)
        let callsAtStop = h.calls.value.count
        session.yield(.datagram(nic: "en0", plane: .multicastDiscovery, source: "fe80::bb", sourceScope: 4, payload: autoToken("fe80::bb")))
        await h.settle()
        // Late events that did get queued, and late ticks, reach a stopped reducer and do nothing.
        await h.store.send(.socketEvent(.datagram(nic: "en0", plane: .multicastDiscovery, source: "fe80::cc", sourceScope: 4, payload: autoToken("fe80::cc"))))
        await h.store.send(.socketEvent(.datagram(nic: "en0", plane: .data, source: "fe80::aa", sourceScope: 4, payload: blob("late"))))
        await h.store.send(.socketEvent(.bindFailed(nic: "en0", plane: .data, errno: EADDRINUSE)))
        await h.store.send(.announceTick)
        await h.store.send(.peerJobTick)
        await h.store.send(.peeringWaitElapsed)
        await h.advance(to: 40)
        #expect(h.store.state.peers.isEmpty && !h.store.state.accepting)
        #expect(h.delegates.value == [.peerAdded(addr: "fe80::aa", nic: "en0")])
        #expect(h.calls.value.count == callsAtStop, "no driver call after stop: \(h.calls.value.dropFirst(callsAtStop))")
        #expect(h.ended.value == 1)
        await h.finish()
    }

    @Test func aStartDuringAStopInFlightWaitsForTheStopToReturn() async {
        let h = AutoHarness()
        await h.store.send(.start)
        await h.settle()
        h.holdStop.setValue(true)
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.settle()
        #expect(h.calls.value.filter { if case .run = $0 { true } else { false } }.count == 1, "deferred")
        h.holdStop.setValue(false)
        for _ in 0..<400 where h.calls.value.filter({ if case .run = $0 { true } else { false } }).count < 2 { await Task.megaYield() }
        let kinds = h.calls.value.compactMap { c -> String? in
            switch c { case .run: "run"; case .stop: "stop"; default: nil }
        }
        #expect(kinds == ["run", "stop", "run"])
        await h.advance(to: 1.92)
        #expect(h.store.state.status == .running)
        await h.finish()
    }
}

/// A host that puts a `.stop` in the SAME burst as the `.start` that builds the stream and timer
/// effects, before any of their tasks has registered its cancel id (see `DriverEpoch`).
private struct AutoBurstHost: Reducer {
    struct State: Equatable { var auto: AutoInterface.State }
    @CasePathable
    enum Action: Equatable {
        case auto(AutoInterface.Action)
        case startThenStop
    }
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case .startThenStop = action { return .concatenate(.send(.auto(.start)), .send(.auto(.stop))) }
            return .none
        }
        Scope(state: \.auto, action: \.auto) { AutoInterface() }
    }
}

@MainActor @Suite struct AutoInterfaceStartEpochTests {
    @Test func aStopInTheStartsBurstLeavesNothingRunning() async {
        for run in 0..<5 {
            let calls = LockIsolated<[AutoCall]>([])
            let clock = TestClock<Duration>()
            let store = TestStore(initialState: AutoBurstHost.State(auto: AutoInterface.State())) {
                AutoBurstHost()
            } withDependencies: {
                $0.autoInterfaceDriver = AutoInterfaceDriver(
                    interfaces: { [autoEn0] },
                    run: { b in calls.withValue { $0.append(.run(b)) }; return AsyncStream { _ in } },
                    rebind: { b in calls.withValue { $0.append(.rebind(b)) } },
                    unbind: { n in calls.withValue { $0.append(.unbind(n)) } },
                    sendMulticast: { n, t, p in calls.withValue { $0.append(.multicast(nic: n, token: t, port: p)) }; return .sent },
                    sendUnicast: { a, i, p, d in calls.withValue { $0.append(.unicast(addr: a, index: i, port: p, datagram: d)) }; return .sent },
                    stop: { calls.withValue { $0.append(.stop) } })
                $0.continuousClock = clock
                $0.date = DateGenerator { Date(timeIntervalSince1970: 1_000_000) }
            }
            store.exhaustivity = .off
            await store.send(.startThenStop)
            for _ in 0..<50 { await Task.megaYield() }
            await clock.advance(by: .seconds(30))
            for _ in 0..<50 { await Task.megaYield() }
            await store.skipReceivedActions(strict: false)
            #expect(calls.value == [.stop], "run \(run): \(calls.value)")
            #expect(store.state.auto.isIdle, "run \(run)")
        }
    }
}

/// The NIC a NIC-scoped delegate names.
func nicOf(_ d: AutoInterface.Action.Delegate) -> String? {
    switch d {
    case let .carrierLost(n), let .carrierRecovered(n), let .multicastUnavailable(n), let .dataPortInUse(n): n
    case let .peerAdded(_, n): n
    default: nil
    }
}

extension Data {
    init(hex: String) {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = out
    }
}
