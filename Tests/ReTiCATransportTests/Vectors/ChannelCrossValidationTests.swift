import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

/// Genuine RNS 1.6.0 `Channel.Envelope.pack()` output (`>HHH` msgtype, sequence, length, payload),
/// including `StreamDataMessage` envelopes. See Vectors/generate_channel_fixtures.py.
private struct ChannelFixtures: Decodable {
    struct Envelope: Decodable {
        let msgtype: UInt16
        let sequence: UInt16
        let payload_hex: String
        let raw_hex: String
        var payload: Data { Data(hexString: payload_hex)! }
        var raw: Data { Data(hexString: raw_hex)! }
    }

    /// A real `RNS.Channel.Channel` fed `sends` through `_receive` from `_next_rx_sequence == start`.
    struct ReceiveScenario: Decodable {
        let name: String
        let start: UInt16
        let sends: [UInt16]
        let delivered: [UInt16]
        let delivered_by_send: [[UInt16]]
        let next_after: UInt16
        let ring_after: [UInt16]
    }

    /// The six window fields of a real `RNS.Channel.Channel`.
    struct WindowState: Decodable, Equatable {
        let window: Int
        let window_max: Int
        let window_min: Int
        let window_flexibility: Int
        let fast_rate_rounds: Int
        let medium_rate_rounds: Int
    }

    /// A real Channel built at `init_rtt`, then driven through `D` (`_packet_delivered`) and `T`
    /// (`_packet_timeout`) events, each at its own rtt; `states` is the state after each event.
    struct WindowScenario: Decodable {
        struct Event: Decodable {
            let op: String
            let rtt: Double
        }
        let name: String
        let init_rtt: Double
        let events: [Event]
        let initial: WindowState
        let states: [WindowState]
    }

    /// `_get_packet_timeout_time(tries)` with `ring` envelopes in the tx ring.
    struct Timeout: Decodable {
        let tries: Int
        let rtt: Double
        let ring: Int
        let timeout: Double
    }

    let envelopes: [Envelope]
    let receive_scenarios: [ReceiveScenario]
    let window_scenarios: [WindowScenario]
    let timeouts: [Timeout]

    static func load() throws -> ChannelFixtures {
        let url = try #require(Bundle.module.url(forResource: "channel_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(ChannelFixtures.self, from: Data(contentsOf: url))
    }
}

@Suite("Channel envelope cross-validation")
struct ChannelCrossValidationTests {
    @Test func theFixtureCoversTheAwkwardCases() throws {
        let envelopes = try ChannelFixtures.load().envelopes
        #expect(envelopes.count == 11)
        #expect(envelopes.contains { $0.payload.isEmpty })
        #expect(envelopes.contains { $0.payload.count == 425 })
        #expect(envelopes.contains { $0.msgtype == 0xFF00 })
    }

    @Test func envelopesPackLikeTheReference() throws {
        for fixture in try ChannelFixtures.load().envelopes {
            let envelope = ChannelEnvelope(msgType: fixture.msgtype, sequence: fixture.sequence, payload: fixture.payload)
            #expect(envelope.packed() == fixture.raw)
        }
    }

    @Test func envelopesParseLikeTheReference() throws {
        for fixture in try ChannelFixtures.load().envelopes {
            let parsed = try #require(ChannelEnvelope.parse(fixture.raw))
            #expect(parsed.msgType == fixture.msgtype)
            #expect(parsed.sequence == fixture.sequence)
            #expect(parsed.payload == fixture.payload)
            #expect(parsed.packed() == fixture.raw)
        }
    }

    @Test func aLengthFieldThatDisagreesIsIgnored() throws {
        let fixture = try #require(ChannelFixtures.load().envelopes.first { $0.payload.count > 1 })
        var raw = fixture.raw
        raw[raw.startIndex + 4] = 0xFF
        raw[raw.startIndex + 5] = 0xFF
        let parsed = try #require(ChannelEnvelope.parse(raw))
        #expect(parsed.payload == fixture.payload)
        #expect(parsed.msgType == fixture.msgtype)
        #expect(parsed.sequence == fixture.sequence)
    }

    @Test func aShortEnvelopeDoesNotParse() {
        for count in 0...5 {
            #expect(ChannelEnvelope.parse(Data(repeating: 0, count: count)) == nil)
        }
        #expect(ChannelEnvelope.parse(Data(repeating: 0, count: 6)) != nil)
    }

    @Test func parseToleratesASlicedInput() throws {
        let fixture = try #require(ChannelFixtures.load().envelopes.first { !$0.payload.isEmpty })
        let padded = Data([0xAA, 0xBB]) + fixture.raw
        let parsed = try #require(ChannelEnvelope.parse(padded.dropFirst(2)))
        #expect(parsed.msgType == fixture.msgtype)
        #expect(parsed.sequence == fixture.sequence)
        #expect(parsed.payload == fixture.payload)
    }

    @Test func systemTypesCannotBeRegistered() {
        #expect(ChannelMessageType(0xEFFF) != nil)
        #expect(ChannelMessageType(0xF000) == nil)
        #expect(ChannelMessageType(0xFF00) == nil)
        #expect(ChannelMessageType.streamData.rawValue == 0xFF00)
    }

    @Test func receiveScenariosMatchTheReference() throws {
        let scenarios = try ChannelFixtures.load().receive_scenarios
        #expect(scenarios.count == 12)
        for scenario in scenarios {
            var ring = ChannelReceiveRing(nextSequence: scenario.start)
            var delivered: [UInt16] = []
            var deliveredBySend: [[UInt16]] = []
            for s in scenario.sends {
                let envelope = ChannelEnvelope(msgType: 0x0101, sequence: s, payload: Data([UInt8(s & 0xFF)]))
                let now = ring.accept(envelope).map(\.sequence)
                deliveredBySend.append(now)
                delivered += now
            }
            #expect(delivered == scenario.delivered, "\(scenario.name)")
            #expect(deliveredBySend == scenario.delivered_by_send, "\(scenario.name)")
            #expect(ring.nextSequence == scenario.next_after, "\(scenario.name)")
            #expect(ring.pending.map(\.sequence) == scenario.ring_after, "\(scenario.name)")
        }
    }

    @Test func windowScenariosMatchTheReference() throws {
        let scenarios = try ChannelFixtures.load().window_scenarios
        #expect(scenarios.map(\.name) == [
            "slow_link_init", "grow_to_slow_max", "promote_medium", "promote_fast", "fast_then_slow_resets",
            "shrink", "shrink_after_medium", "shrink_after_fast", "shrink_max_floor", "slow_link_traffic",
            "rtt_zero_skips_rate_tracking", "rtt_boundaries",
        ])
        for scenario in scenarios {
            var window = ChannelSendWindow(linkRTT: scenario.init_rtt)
            #expect(Self.state(window) == scenario.initial, "\(scenario.name) initial")
            #expect(scenario.events.count == scenario.states.count, "\(scenario.name)")
            for (index, (event, expected)) in zip(scenario.events, scenario.states).enumerated() {
                switch event.op {
                case "D": window.delivered(linkRTT: event.rtt)
                case "T": window.timedOut()
                default: Issue.record("\(scenario.name): unknown op \(event.op)")
                }
                #expect(Self.state(window) == expected, "\(scenario.name) event \(index) \(event.op)")
            }
        }
    }

    private static func state(_ w: ChannelSendWindow) -> ChannelFixtures.WindowState {
        ChannelFixtures.WindowState(
            window: w.window, window_max: w.windowMax, window_min: w.windowMin,
            window_flexibility: w.windowFlexibility, fast_rate_rounds: w.fastRateRounds,
            medium_rate_rounds: w.mediumRateRounds)
    }

    @Test func timeoutsMatchTheReference() throws {
        let cases = try ChannelFixtures.load().timeouts
        #expect(cases.count == 30)
        for c in cases {
            let ours = ChannelSendWindow.timeout(tries: c.tries, linkRTT: c.rtt, txRingCount: c.ring)
            #expect(abs(ours - c.timeout) < 1e-9, "tries \(c.tries) rtt \(c.rtt) ring \(c.ring): \(ours) vs \(c.timeout)")
        }
    }

    @Test func theConstantsMatchTheReference() {
        #expect(ChannelConstants.window == 2)
        #expect(ChannelConstants.windowMin == 2)
        #expect(ChannelConstants.windowMinLimitSlow == 2)
        #expect(ChannelConstants.windowMinLimitMedium == 5)
        #expect(ChannelConstants.windowMinLimitFast == 16)
        #expect(ChannelConstants.windowMaxSlow == 5)
        #expect(ChannelConstants.windowMaxMedium == 12)
        #expect(ChannelConstants.windowMaxFast == 48)
        #expect(ChannelConstants.windowMax == 48)
        #expect(ChannelConstants.fastRateThreshold == 10)
        #expect(ChannelConstants.rttFast == 0.18)
        #expect(ChannelConstants.rttMedium == 0.75)
        #expect(ChannelConstants.rttSlow == 1.45)
        #expect(ChannelConstants.windowFlexibility == 4)
        #expect(ChannelConstants.seqMax == 0xFFFF)
        #expect(ChannelConstants.seqModulus == 0x10000)
        #expect(ChannelConstants.maxTries == 5)
        #expect(ChannelConstants.envelopeOverhead == 6)
    }
}
