import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// Replays the behaviour traces recorded from the REAL RNS 1.6.0 `discovery_handler` and
/// `process_incoming` (Vectors/generate_autointerface_traces.py, spec §7.1 item 5) into the reducer,
/// and compares the peer table, the echo tables and data delivery after every step.
@MainActor @Suite struct AutoInterfaceTraceTests {
    struct Traces: Decodable {
        struct NIC: Decodable { let name: String; let index: UInt32; let addrs: [String] }
        struct Step: Decodable {
            let t: Double
            let kind: String
            let nic: String?
            let plane: String?
            let src: String?
            let payload: String?
        }
        struct PeerRow: Decodable, Equatable { let nic: String; let last_heard: Double }
        struct EchoRow: Decodable, Equatable { let last: Double?; let initial: Double? }
        struct Result: Decodable {
            let peers: [String: PeerRow]
            let echoes: [String: EchoRow]
            let accepting: Bool
            let delivered: Bool?
        }
        struct Trace: Decodable {
            let name: String
            let group_id_hex: String
            let nics: [NIC]
            let steps: [Step]
            let results: [Result]
        }
        let traces: [Trace]
    }

    struct FixturesMissing: Error {}

    static func load() throws -> Traces {
        guard let url = Bundle.module.url(forResource: "autointerface_traces", withExtension: "json")
        else { throw FixturesMissing() }
        return try JSONDecoder().decode(Traces.self, from: Data(contentsOf: url))
    }

    @Test(arguments: ["discovery", "dedupe"])
    func replayMatchesTheReference(_ name: String) async throws {
        let trace = try #require(try Self.load().traces.first { $0.name == name })
        let nics = trace.nics.map { AutoNIC(name: $0.name, index: $0.index, linkLocals: $0.addrs) }
        let h = AutoHarness(nics: nics, config: AutoInterfaceConfig(groupID: Data(hex: trace.group_id_hex)))
        await h.store.send(.start)
        await h.settle()
        func offset(_ d: Date?) -> Double? { d.map { $0.timeIntervalSince(AutoHarness.base) } }
        var delivered = 0

        for (i, (step, want)) in zip(trace.steps, trace.results).enumerated() {
            await h.advance(to: step.t)
            switch step.kind {
            case "final_init":
                break   // the reducer's own 1.92 s timer (AI:332, AI:353-356)
            case "discovery":
                let nic = try #require(nics.first { $0.name == step.nic })
                let plane: AutoPlane = step.plane == "unicastDiscovery" ? .unicastDiscovery : .multicastDiscovery
                await h.discovery(nic, from: step.src!, payload: Data(hex: step.payload!), plane: plane)
            case "data":
                // The reference dispatches by source only (AI:613-615): the arrival NIC is irrelevant.
                await h.data(nics[0], from: step.src!, Data(hex: step.payload!))
            default:
                Issue.record("unknown step \(step.kind)")
            }

            let s = h.store.state
            #expect(s.accepting == want.accepting, "step \(i) t=\(step.t)")
            let got = s.peers.mapValues { Traces.PeerRow(nic: $0.nic, last_heard: offset($0.lastHeard)!) }
            #expect(got == want.peers, "step \(i) t=\(step.t): peers")
            for (nicName, row) in want.echoes {
                let n = try #require(s.nics[nicName])
                #expect(offset(n.lastEcho) == row.last, "step \(i) t=\(step.t): \(nicName) last echo")
                #expect(offset(n.firstEcho) == row.initial, "step \(i) t=\(step.t): \(nicName) first echo")
            }
            let packets = h.delegates.value.filter { if case .packetReceived = $0 { true } else { false } }.count
            if let d = want.delivered {
                #expect((packets == delivered + 1) == d, "step \(i) t=\(step.t): delivered")
            }
            #expect(packets - delivered <= 1, "step \(i): more than one delivery")
            delivered = packets
        }
        let added = h.delegates.value.filter { if case .peerAdded = $0 { true } else { false } }.count
        #expect(added == trace.results.last!.peers.count, "one peerAdded per reference peer")
        await h.finish()
    }
}
