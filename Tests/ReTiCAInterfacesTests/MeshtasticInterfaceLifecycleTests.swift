import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@MainActor @Suite struct MeshtasticInterfaceLifecycleTests {
    @Test func startHandsTheConfigToTheDriver() async {
        let h = await makeOnlineMeshInterface()
        #expect(h.calls.value.first == .start(meshTestConfig))
        await stopMeshInterface(h)
    }

    @Test func connectedEventReportsOnlineWithItsPreset() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 8))
        await h.store.receive { $0 == .delegate(.online(myNodeNum: meshOwnNode, modemPreset: 8)) }
        await stopMeshInterface(h)
    }

    @Test func fragmentsFromAPeerReassembleIntoOnePacket() async {
        let h = await makeOnlineMeshInterface()
        let packet = meshPattern(400, seed: 9)
        for frame in LandandairCodec().split(packet, index: 4) {
            h.radio.yield(.fragment(from: meshPeerNode, frame))
        }
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        await stopMeshInterface(h)
    }

    @Test func malformedFrameIncrementsTheMalformedCounter() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.fragment(from: meshPeerNode, Data([0x01])))
        await h.store.receive { if case .driverEvent(.fragment) = $0 { return true }; return false }
        #expect(h.store.state.reassembler.counters.malformed == 1)
        await stopMeshInterface(h)
    }

    @Test func fragmentsBeforeTheRadioIsOnlineAreDropped() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        let frames = LandandairCodec().split(meshPattern(300, seed: 1), index: 0)
        h.radio.yield(.fragment(from: meshPeerNode, frames[0]))
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        h.radio.yield(.fragment(from: meshPeerNode, frames[1]))
        await h.store.receive { if case let .driverEvent(.fragment(_, f)) = $0 { return f == frames[1] }; return false }
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshInterface(h)
    }

    @Test func disconnectReportsOfflineWithTheReason() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.disconnected(reason: "link lost"))
        await h.store.receive { $0 == .delegate(.offline(reason: "link lost")) }
        await stopMeshInterface(h)
    }

    @Test func disconnectDiscardsPartialReassembly() async {
        let h = await makeOnlineMeshInterface()
        let frames = LandandairCodec().split(meshPattern(300, seed: 2), index: 0)
        h.radio.yield(.fragment(from: meshPeerNode, frames[0]))
        h.radio.yield(.disconnected(reason: nil))
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        h.radio.yield(.fragment(from: meshPeerNode, frames[1]))
        await h.store.receive { if case let .driverEvent(.fragment(_, f)) = $0 { return f == frames[1] }; return false }
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshInterface(h)
    }

    @Test func unavailableSurfacesTheCause() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        await stopMeshInterface(h)
    }

    @Test func unavailableWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.unavailable(.unauthorized))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await stopMeshInterface(h)
    }

    @Test func stopWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    @Test func stopStopsTheDriver() async {
        let h = await makeOnlineMeshInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.calls.value.contains(.stop))
    }
}
