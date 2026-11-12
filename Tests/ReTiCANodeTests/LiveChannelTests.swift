import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA

// LIVE INTEROP: RNS Channel and Buffer between a ReTiCA TransportEndpoint and a reference RNS 1.6.0
// peer, once with ReTiCA as the link initiator and once as the responder. Off by default:
//
//   RETICA_LIVE_CHANNEL_PYTHON=/Users/ell/opt/anaconda3/envs/rns-latest/bin/python \
//     swift test --no-parallel --filter LiveChannel
//
// The peer is Scripts/channelprobe/peer.py, a TCP server on the fixed port 49741 that ReTiCA dials
// directly (no hub). It echoes EchoMessage (0x0101) payloads reversed and stream 1 onto stream 2,
// and leaves the first CHANNEL packet it receives unproven, so the sender must resend it. Its
// milestone lines arrive on stdout; its RNS log goes to /tmp/ReTiCA/live-channel-<mode>-<id>.stderr,
// which every failure message names.

private let pythonPath = ProcessInfo.processInfo.environment["RETICA_LIVE_CHANNEL_PYTHON"]
private let peerScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Scripts/channelprobe/peer.py").path
private let peerPort: UInt16 = 49741
/// The repo's temp folder: the peer's RNS config dir (removed at teardown) and its log (kept).
private let tempRoot = "/tmp/ReTiCA"
private let echoType = ChannelMessageType(0x0101)!

@MainActor
private func poll<T>(seconds: Double, _ value: () -> T?) async -> T? {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let found = value() { return found }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return value()
}

/// What the harness saw, rendered Sendable (`TransportEndpoint.Action.Delegate` is not).
private enum Event: Equatable, Sendable {
    case established(linkID: Data)
    case closed(linkID: Data, reason: LinkSession.CloseReason)
    case failed(String)
    case message(msgType: UInt16, payload: Data)
    case delivered(token: Data)
    case rejected(token: Data, reason: String)
    case stream(streamID: UInt16, data: Data, eof: Bool)
    case written(token: Data, consumed: Int)
    /// A CHANNEL packet we put on the wire, decrypted under the link's session key.
    case channelTransmit(sequence: UInt16, msgType: UInt16)
    /// A stream-data envelope on the wire, ours (`outbound`) or the peer's, by its header; resends
    /// are counted again.
    case streamChunk(outbound: Bool, streamID: UInt16, compressed: Bool)
}

/// The stream-data header of a CHANNEL packet on one of `links`, or nil.
private func channelEnvelope(_ raw: Data, _ links: IdentifiedArrayOf<LinkSession.State>) -> ChannelEnvelope? {
    guard let packet = Packet(raw: raw), packet.packetType == .data, packet.context == .channel,
          let link = links.first(where: { $0.linkID == packet.destinationHash }),
          let plain = Link.decrypt(packet.payload, sessionKey: link.sessionKey)
    else { return nil }
    return ChannelEnvelope.parse(plain)
}

private func streamHeader(_ envelope: ChannelEnvelope) -> StreamDataHeader? {
    guard envelope.msgType == 0xFF00 else { return nil }
    return StreamDataHeader.parse(envelope.payload)?.0
}

/// `count` bytes: text lines (which bz2 compresses, so the writer sends compressed chunks) for the
/// first half, then LCG bytes (which it sends raw). peer.py's `originated_stream` builds the same.
private func mixedStream(count: Int, linePrefix: String) -> Data {
    var out = Data()
    var line = 0
    while out.count < count / 2 {
        out += Data(String(format: "\(linePrefix) stream line %04d\n", line).utf8)
        line += 1
    }
    out = out.prefix(count / 2)
    var x: UInt32 = 1
    while out.count < count {
        x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
        out.append(UInt8(truncatingIfNeeded: x >> 16))
    }
    return out
}

/// A TransportEndpoint that records its delegates and channel transmits, and opens the channel,
/// registers 0x0101 and opens stream reader 2 the moment a link is established, so nothing the
/// peer sends right after establishment finds the channel closed.
@Reducer
private struct ChannelHarness {
    @ObservableState
    struct State: Equatable {
        var endpoint = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "127.0.0.1", port: peerPort,
                                                                     reconnectOnDrop: true))
    }
    enum Action { case endpoint(TransportEndpoint.Action) }

    let sink: @Sendable (Event) -> Void

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Reduce { state, action in
            guard case let .endpoint(endpointAction) = action else { return .none }
            switch endpointAction {
            case let .linkPlane(.delegate(.transmit(_, raw))):
                guard let envelope = channelEnvelope(raw, state.endpoint.links) else { return .none }
                sink(.channelTransmit(sequence: envelope.sequence, msgType: envelope.msgType))
                if let header = streamHeader(envelope) {
                    sink(.streamChunk(outbound: true, streamID: header.streamID, compressed: header.compressed))
                }
                return .none
            case let .tcpClients(.element(_, .interface(.delegate(.packetReceived(raw))))):
                if let envelope = channelEnvelope(raw, state.endpoint.links), let header = streamHeader(envelope) {
                    sink(.streamChunk(outbound: false, streamID: header.streamID, compressed: header.compressed))
                }
                return .none
            case let .delegate(d):
                switch d {
                case let .linkEstablished(linkID, _):
                    sink(.established(linkID: linkID))
                    return .concatenate(.send(.endpoint(.openChannelOverLink(linkID: linkID))),
                                        .send(.endpoint(.registerChannelMessageTypeOverLink(linkID: linkID,
                                                                                            type: echoType))),
                                        .send(.endpoint(.openStreamReaderOverLink(linkID: linkID, streamID: 2))))
                case let .linkClosed(linkID, reason):     sink(.closed(linkID: linkID, reason: reason))
                case let .linkFailed(_, reason):          sink(.failed("\(reason)"))
                case let .channelMessageReceived(_, t, p): sink(.message(msgType: t, payload: p))
                case let .channelMessageDelivered(_, token): sink(.delivered(token: token))
                case let .channelSendRejected(_, token, reason): sink(.rejected(token: token, reason: "\(reason)"))
                case let .streamDataReceived(_, s, data, eof): sink(.stream(streamID: s, data: data, eof: eof))
                case let .streamWritten(_, token, consumed): sink(.written(token: token, consumed: consumed))
                default: break
                }
                return .none
            default:
                return .none
            }
        }
    }
}

/// peer.py as a child process: stdout lines collected, stderr to a kept log file, the RNS config
/// dir removed and the process killed (SIGTERM, then SIGKILL) by `stop()`.
@MainActor
private final class ReferencePeer {
    let process = Process()
    let dir: String
    let stderrPath: String
    let lines = LockIsolated<[String]>([])
    private let partial = LockIsolated<String>("")
    private let stdout = Pipe()
    private let stderr: FileHandle

    struct SetupError: Error, CustomStringConvertible { var description: String }

    init(mode: String) throws {
        let id = UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        dir = "\(tempRoot)/live-channel-\(mode)-\(id)"
        stderrPath = "\(dir).stderr"
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: stderrPath) else {
            throw SetupError(description: "cannot open \(stderrPath)")
        }
        stderr = handle
        process.executableURL = URL(fileURLWithPath: pythonPath!)
        process.arguments = ["-u", peerScript, "--dir", dir, "--listen", "\(peerPort)", "--mode", mode]
        process.standardOutput = stdout
        process.standardError = stderr
        let lines = self.lines, partial = self.partial
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            partial.withValue { buffer in
                buffer += String(decoding: chunk, as: UTF8.self)
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<newline])
                    buffer = String(buffer[buffer.index(after: newline)...])
                    lines.withValue { $0.append(line) }
                }
            }
        }
        try process.run()
    }

    /// The rest of the first stdout line starting `prefix `.
    func value(after prefix: String) -> String? {
        lines.value.first { $0.hasPrefix(prefix + " ") }.map { String($0.dropFirst(prefix.count + 1)) }
    }

    func has(_ line: String) -> Bool { lines.value.contains(line) }

    /// For failure messages: the milestones so far and where the RNS log is.
    var report: String {
        "peer stdout: \(lines.value); peer RNS log: \(stderrPath)"
    }

    func stop() {
        if process.isRunning { process.terminate() }
        let end = Date().addingTimeInterval(5)
        while process.isRunning && Date() < end { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stderr.close()
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Wait for READY; nil (with an issue recorded) if the peer exits or never gets there.
    func waitUntilReady() async -> Data? {
        let ready = await poll(seconds: 30) { () -> String?? in
            if let hex = value(after: "READY") { return .some(hex) }
            return process.isRunning ? nil : .some(nil)
        }
        guard let hex = ready ?? nil, let hash = Data(hexString: hex) else {
            let reason = process.isRunning ? "no READY after 30 s" : "exited with status \(process.terminationStatus)"
            Issue.record("The reference peer did not start (\(reason)). \(report)")
            return nil
        }
        return hash
    }
}

@Suite(.serialized, .enabled(if: pythonPath != nil), .timeLimit(.minutes(3)))
@MainActor struct LiveChannelTests {
    private func makeStore(_ events: LockIsolated<[Event]>) -> StoreOf<ChannelHarness> {
        // `.live`: in a test context several ReTiCA dependencies (clocks, \.transportDate) are
        // unimplemented, which would trap before anything reaches the network.
        Store(initialState: ChannelHarness.State()) {
            ChannelHarness { event in events.withValue { $0.append(event) } }
        } withDependencies: { $0.context = .live }
    }

    private func exhaustedClose(_ events: LockIsolated<[Event]>) -> Bool {
        events.value.contains {
            if case .closed(_, .channelRetriesExhausted) = $0 { return true }
            return false
        }
    }

    private func linkClosed(_ events: LockIsolated<[Event]>) -> Bool {
        events.value.contains {
            if case .closed = $0 { return true }
            return false
        }
    }

    private func messages(_ events: LockIsolated<[Event]>) -> [Data] {
        events.value.compactMap {
            if case let .message(t, p) = $0, t == echoType.rawValue { return p }
            return nil
        }
    }

    /// Everything received on `streamID`, and whether EOF arrived.
    private func stream(_ events: LockIsolated<[Event]>, _ streamID: UInt16) -> (data: Data, eof: Bool) {
        events.value.reduce(into: (data: Data(), eof: false)) { acc, event in
            if case let .stream(s, data, eof) = event, s == streamID {
                acc.data += data
                acc.eof = acc.eof || eof
            }
        }
    }

    /// How many stream-data chunks went one way on `streamID`, compressed and raw.
    private func chunks(_ events: LockIsolated<[Event]>, outbound: Bool,
                        streamID: UInt16) -> (compressed: Int, raw: Int) {
        events.value.reduce(into: (compressed: 0, raw: 0)) { acc, event in
            if case let .streamChunk(o, s, compressed) = event, o == outbound, s == streamID {
                if compressed { acc.compressed += 1 } else { acc.raw += 1 }
            }
        }
    }

    private func transmits(_ events: LockIsolated<[Event]>, sequence: UInt16) -> Int {
        events.value.filter { $0 == .channelTransmit(sequence: sequence, msgType: echoType.rawValue) }.count
    }

    /// Send one 0x0101 message and wait for its proof. Paced one at a time, so the window (2 at
    /// start) is never full and `.notReady` cannot occur.
    private func sendDelivered(_ store: StoreOf<ChannelHarness>, _ events: LockIsolated<[Event]>,
                               linkID: Data, payload: Data, token: Data, peer: ReferencePeer) async -> Bool {
        store.send(.endpoint(.sendChannelMessageOverLink(linkID: linkID, type: echoType, payload: payload, token: token)))
        let outcome = await poll(seconds: 20) { () -> Bool? in
            for event in events.value {
                if event == .delivered(token: token) { return true }
                if case let .rejected(t, _) = event, t == token { return false }
            }
            return linkClosed(events) ? false : nil
        }
        if outcome != true {
            Issue.record("message \(String(decoding: payload, as: UTF8.self)) not delivered; events: \(events.value.filter { if case .channelTransmit = $0 { return false }; if case .streamChunk = $0 { return false }; return true }); \(peer.report)")
        }
        return outcome == true
    }

    // MARK: ReTiCA initiates

    @Test func retiCAInitiatesAndExchangesChannelMessagesAndStreams() async throws {
        let peer = try ReferencePeer(mode: "accept")
        defer { peer.stop() }
        guard let peerHash = await peer.waitUntilReady() else { return }

        let events = LockIsolated<[Event]>([])
        let store = makeStore(events)
        store.send(.endpoint(.start))
        defer { store.send(.endpoint(.stop)) }

        // The peer announces every second until a link arrives.
        let learned = await poll(seconds: 30) { store.state.endpoint.transport.learned[peerHash] != nil ? true : nil }
        guard learned == true else {
            Issue.record("no path to the peer \(peerHash.hexString) after 30 s; \(peer.report)")
            return
        }

        // 1. Link, channel, 0x0101, stream reader 2 (the harness does the last three on establishment).
        store.send(.endpoint(.openLink(destinationHash: peerHash)))
        let established = await poll(seconds: 25) { () -> Data?? in
            for event in events.value {
                if case let .established(id) = event { return .some(id) }
                if case .failed = event { return .some(nil) }
            }
            return nil
        }
        guard let linkID = established ?? nil else {
            Issue.record("link not established; events: \(events.value); \(peer.report)")
            return
        }
        let peerLink = await poll(seconds: 10) { peer.value(after: "LINK") }
        #expect(peerLink == linkID.hexString, "the peer's link is not ours; \(peer.report)")
        #expect(store.state.endpoint.links.first { $0.linkID == linkID }?.channel != nil)

        // 2. Three messages, three reversed echoes; the first send unproven once, so resent.
        let payloads = (0..<3).map { Data("retica-\($0)".utf8) }
        for (n, payload) in payloads.enumerated() {
            guard await sendDelivered(store, events, linkID: linkID, payload: payload,
                                      token: Data("msg-\(n)".utf8), peer: peer) else { return }
        }
        let echoes = await poll(seconds: 20) { messages(events).count >= 3 ? messages(events) : nil }
        #expect(echoes == payloads.map { Data($0.reversed()) },
                "echoes \(messages(events).map { String(decoding: $0, as: UTF8.self) }); \(peer.report)")
        #expect(peer.value(after: "SKIPPED_PROOF") != nil, "the peer proved every packet; \(peer.report)")
        let firstSends = transmits(events, sequence: 0)
        print("LIVE-CHANNEL initiator: sequence 0 went out \(firstSends) times")
        #expect(firstSends >= 2, "sequence 0 was not resent after the peer left it unproven")

        // 3. 40 000 bytes on stream 1, then EOF; the same bytes and EOF back on stream 2.
        let sent = mixedStream(count: 40_000, linePrefix: "retica")
        var offset = 0
        var write = 0
        var writeTokens: [Data] = []
        let writeDeadline = Date().addingTimeInterval(90)
        while offset < sent.count {
            guard Date() < writeDeadline, !linkClosed(events) else {
                Issue.record("stream write stalled at \(offset) of \(sent.count); \(peer.report)")
                return
            }
            let token = Data("write-\(write)".utf8)
            write += 1
            store.send(.endpoint(.writeStreamOverLink(linkID: linkID, streamID: 1, data: sent.subdata(in: offset..<sent.count),
                                                      token: token)))
            let consumed = await poll(seconds: 5) { () -> Int? in
                for event in events.value { if case let .written(t, c) = event, t == token { return c } }
                return nil
            }
            guard let consumed else {
                Issue.record("no streamWritten for \(token); \(peer.report)")
                return
            }
            if consumed > 0 {
                offset += consumed
                writeTokens.append(token)
            } else {
                // Not ready: the window is full until a delivery frees a slot.
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        // EOF only once every chunk is proven, so the close finds the channel ready and is not lost.
        let allDelivered = await poll(seconds: 30) { () -> Bool? in
            let delivered = Set(events.value.compactMap { if case let .delivered(t) = $0 { return t }; return nil })
            return writeTokens.allSatisfy(delivered.contains) ? true : nil
        }
        #expect(allDelivered == true, "not every stream chunk was proven; \(peer.report)")
        store.send(.endpoint(.closeStreamWriterOverLink(linkID: linkID, streamID: 1, token: Data("eof".utf8))))

        let back = await poll(seconds: 60) { stream(events, 2).eof ? stream(events, 2) : nil }
        #expect(back?.eof == true, "no EOF on stream 2; got \(stream(events, 2).data.count) bytes; \(peer.report)")
        #expect(back?.data == sent, "stream 2 returned \(back?.data.count ?? 0) bytes, not the 40000 sent")
        #expect(peer.value(after: "STREAM_EOF") == "40000", "\(peer.report)")
        // Both chunk kinds crossed both ways: bz2 from us inflated by the reference, and its bz2
        // inflated by us.
        let ours = chunks(events, outbound: true, streamID: 1)
        let theirs = chunks(events, outbound: false, streamID: 2)
        print("LIVE-CHANNEL initiator: stream 1 out \(ours), stream 2 in \(theirs) (compressed, raw)")
        #expect(ours.compressed > 0 && ours.raw > 0, "stream 1 chunks out: \(ours)")
        #expect(theirs.compressed > 0 && theirs.raw > 0, "stream 2 chunks in: \(theirs)")

        #expect(!exhaustedClose(events), "a link closed with .channelRetriesExhausted; \(peer.report)")
        #expect(!linkClosed(events), "the link closed during the exchange; events: \(events.value.filter { if case .closed = $0 { return true }; return false })")
    }

    // MARK: The reference initiates

    @Test func referenceInitiatesAndExchangesChannelMessagesAndStreams() async throws {
        let peer = try ReferencePeer(mode: "initiate")
        defer { peer.stop() }
        guard await peer.waitUntilReady() != nil else { return }

        let events = LockIsolated<[Event]>([])
        let store = makeStore(events)
        let identity = Identity()
        let destination = try #require(Destination(kind: .single, direction: .in, appName: "channelprobe",
                                                   aspects: ["retica"], identity: identity))
        store.send(.endpoint(.registerLocalDestination(destination)))
        store.send(.endpoint(.start))
        defer { store.send(.endpoint(.stop)) }

        let online = await poll(seconds: 30) {
            store.state.endpoint.tcpClients.first?.interface.status == .online ? true : nil
        }
        guard online == true else {
            Issue.record("never connected to the peer on \(peerPort); \(peer.report)")
            return
        }

        // 1. Announce channelprobe.retica until the peer's link is established (the harness opens
        // the channel, registers 0x0101 and opens stream reader 2 at that moment).
        var nextAnnounce = Date.distantPast
        let established = await poll(seconds: 40) { () -> Data? in
            for event in events.value { if case let .established(id) = event { return id } }
            if Date() >= nextAnnounce {
                store.send(.endpoint(.announce(destinationHash: destination.hash, appData: nil)))
                nextAnnounce = Date().addingTimeInterval(2)
            }
            return nil
        }
        guard let linkID = established else {
            Issue.record("the peer never linked to \(destination.hash.hexString); events: \(events.value); \(peer.report)")
            return
        }
        let peerLink = await poll(seconds: 10) { peer.value(after: "LINK") }
        #expect(peerLink == linkID.hexString, "the peer's link is not ours; \(peer.report)")
        #expect(store.state.endpoint.links.first { $0.linkID == linkID }?.role == .responder)

        // 2. from-ref-0..2 in order, then 5000 bytes and EOF on stream 2.
        let expected = (0..<3).map { Data("from-ref-\($0)".utf8) }
        let firstThree = await poll(seconds: 20) { messages(events).count >= 3 ? Array(messages(events).prefix(3)) : nil }
        #expect(firstThree == expected,
                "received \(messages(events).map { String(decoding: $0, as: UTF8.self) }); \(peer.report)")
        let pattern = mixedStream(count: 5000, linePrefix: "from-ref")
        let streamed = await poll(seconds: 30) { stream(events, 2).eof ? stream(events, 2) : nil }
        #expect(streamed?.eof == true, "no EOF on stream 2; got \(stream(events, 2).data.count) bytes; \(peer.report)")
        #expect(streamed?.data == pattern, "stream 2 carried \(streamed?.data.count ?? 0) bytes, not the peer's 5000")
        let theirs = chunks(events, outbound: false, streamID: 2)
        print("LIVE-CHANNEL responder: stream 2 in \(theirs) (compressed, raw)")
        #expect(theirs.compressed > 0 && theirs.raw > 0, "stream 2 chunks in: \(theirs)")

        // 3. Echo them back; the peer prints GOT for each, so our responder-side sends were proven
        // by the peer and its proofs validated here, or the pacing below would never advance.
        for (n, payload) in expected.enumerated() {
            guard await sendDelivered(store, events, linkID: linkID, payload: payload,
                                      token: Data("echo-\(n)".utf8), peer: peer) else { return }
        }
        let gotAll = await poll(seconds: 20) {
            expected.allSatisfy { peer.has("GOT 0101 \($0.hexString)") } ? true : nil
        }
        #expect(gotAll == true, "the peer did not GOT every echo; \(peer.report)")
        #expect(peer.value(after: "SKIPPED_PROOF") != nil, "the peer proved every packet; \(peer.report)")
        let firstSends = transmits(events, sequence: 0)
        print("LIVE-CHANNEL responder: sequence 0 went out \(firstSends) times")
        #expect(firstSends >= 2, "sequence 0 was not resent after the peer left it unproven")

        // 4.
        #expect(!exhaustedClose(events), "a link closed with .channelRetriesExhausted; \(peer.report)")
        #expect(!linkClosed(events), "the link closed during the exchange; events: \(events.value.filter { if case .closed = $0 { return true }; return false })")
    }
}
