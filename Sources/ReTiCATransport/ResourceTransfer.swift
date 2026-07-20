import Foundation
import ComposableArchitecture
import ReTiCA

/// A single-segment Reticulum Resource transfer (one instance per resource) as a TCA feature.
/// Interface-agnostic: raw resource-packet bytes arrive via `advertise`/`accept`/`received`;
/// outbound bytes leave via `delegate(.transmit)`. Uses the pure `Resource` primitives + the
/// link's session key. Windowed receiver: requests parts a window at a time, grows the window
/// as rounds complete, retransmits on timeout, and fails after MAX_RETRIES.
@Reducer
public struct ResourceTransfer {
    public enum Role: Equatable, Sendable { case sender, receiver }
    public enum Status: Equatable, Sendable { case idle, advertised, requesting, transferring, awaitingProof, complete, failed }

    @ObservableState
    public struct State: Equatable, Identifiable {
        public let id: UUID
        public var role: Role
        public var status: Status
        public var interfaceID: InterfaceID
        public var linkID: Data
        public var sessionKey: Data
        public var resourceHash: Data
        // sender
        public var parts: [Data]
        public var partMapHashes: [Data]
        public var advertisement: ResourceAdvertisement?
        public var expectedProof: Data
        // receiver
        public var randomHash: Data
        public var expectedParts: UInt64
        public var receivedParts: [Int: Data]
        // windowing / retransmission (receiver)
        public var window: ResourceWindow
        public var consecutiveCompletedHeight: Int
        public var outstanding: Set<Int>
        public var retriesLeft: Int
        public var partTimeoutFactor: Int
        public var receivedFirstPart: Bool
        public var rtt: Duration
        // sender timers
        public var sentIndices: Set<Int>
        public var advRetriesLeft: Int
        public var proofRetriesLeft: Int

        /// Sender: build the resource from `data` over the link's session key.
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, rtt: Duration = .seconds(1), id: UUID = UUID()) {
            self.id = id
            self.role = .sender
            self.status = .idle
            self.interfaceID = interfaceID
            self.linkID = linkID
            self.sessionKey = sessionKey
            self.randomHash = randomHash
            let stream = Resource.buildStream(data: data, prefix: prefix, sessionKey: sessionKey)
            let chunks = Resource.parts(stream: stream, sdu: sdu)
            let mapHashes = chunks.map { Resource.mapHash(chunk: $0, randomHash: randomHash) }
            let h = Resource.resourceHash(data: data, randomHash: randomHash)
            self.parts = chunks
            self.partMapHashes = mapHashes
            self.resourceHash = h
            self.expectedProof = Resource.expectedProof(data: data, hash: h)
            self.expectedParts = UInt64(chunks.count)
            self.receivedParts = [:]
            self.advertisement = ResourceAdvertisement(
                transferSize: UInt64(stream.count), dataSize: UInt64(data.count),
                numberOfParts: UInt64(chunks.count), hash: h, randomHash: randomHash, originalHash: h,
                segmentIndex: 0, totalSegments: 1, requestID: nil, flags: 0x01,
                hashmap: mapHashes.reduce(Data()) { $0 + $1 })
            self.window = ResourceWindow()
            self.consecutiveCompletedHeight = -1
            self.outstanding = []
            self.retriesLeft = Const.maxRetries
            self.partTimeoutFactor = Const.partTimeoutFactor
            self.receivedFirstPart = false
            self.rtt = rtt
            self.sentIndices = []
            self.advRetriesLeft = Const.maxAdvRetries
            self.proofRetriesLeft = Const.proofRetries
        }

        /// Receiver: accept an inbound resource on the given link.
        public init(receivingOn linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    rtt: Duration = .seconds(1), id: UUID = UUID()) {
            self.id = id
            self.role = .receiver
            self.status = .idle
            self.interfaceID = interfaceID
            self.linkID = linkID
            self.sessionKey = sessionKey
            self.resourceHash = Data()
            self.parts = []
            self.partMapHashes = []
            self.advertisement = nil
            self.expectedProof = Data()
            self.randomHash = Data()
            self.expectedParts = 0
            self.receivedParts = [:]
            self.window = ResourceWindow()
            self.consecutiveCompletedHeight = -1
            self.outstanding = []
            self.retriesLeft = Const.maxRetries
            self.partTimeoutFactor = Const.partTimeoutFactor
            self.receivedFirstPart = false
            self.rtt = rtt
            self.sentIndices = []
            self.advRetriesLeft = Const.maxAdvRetries
            self.proofRetriesLeft = Const.proofRetries
        }
    }

    public enum Action: Equatable {
        case advertise
        case accept(Data)
        case received(Data)
        case receiverDeadline
        case senderDeadline
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(Data)
            case concluded
            case failed
        }
    }

    public init() {}

    @Dependency(\.continuousClock) var clock

    enum Const {
        static let maxRetries = 16
        static let maxAdvRetries = 4
        static let proofRetries = 3
        static let partTimeoutFactor = 4
        static let partTimeoutFactorAfterRTT = 2
        static let proofTimeoutFactor = 3
        static let retryGrace: Duration = .milliseconds(250)
        static let perRetryDelay: Duration = .milliseconds(500)
        static let senderGrace: Duration = .seconds(10)
        static let processingGrace: Duration = .seconds(1)
    }

    enum CancelID: Hashable { case watchdog }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            func linkPacket(_ type: PacketType, _ context: PacketContext, _ payload: Data) -> Data? {
                let p = Packet(headerType: .header1, packetType: type, transportType: .broadcast,
                               destinationType: .link, context: context, contextFlag: false, hops: 0,
                               destinationHash: state.linkID, transportId: nil, payload: payload)
                return try? p.packed()
            }

            func armReceiverWatchdog(_ s: State) -> Effect<Action> {
                let timeout = s.rtt * s.partTimeoutFactor
                    + Const.retryGrace
                    + Const.perRetryDelay * (Const.maxRetries - s.retriesLeft)
                let c = clock
                return .run { send in
                    try await c.sleep(for: timeout)
                    await send(.receiverDeadline)
                }.cancellable(id: CancelID.watchdog, cancelInFlight: true)
            }

            func armSenderWatchdog(_ s: State) -> Effect<Action> {
                let timeout: Duration
                switch s.status {
                case .advertised:
                    timeout = s.rtt * Const.partTimeoutFactor + Const.processingGrace
                case .transferring:
                    timeout = s.rtt * Const.partTimeoutFactor * Const.maxRetries + Const.senderGrace
                case .awaitingProof:
                    timeout = s.rtt * Const.proofTimeoutFactor + Const.senderGrace
                default:
                    return .none
                }
                let c = clock
                return .run { send in
                    try await c.sleep(for: timeout)
                    await send(.senderDeadline)
                }.cancellable(id: CancelID.watchdog, cancelInFlight: true)
            }

            func senderCancel(_ s: State) -> Effect<Action> {
                guard let icl = linkPacket(.data, .resourceInitiatorCancel,
                                           Link.encrypt(s.resourceHash, sessionKey: s.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(s.interfaceID, icl)))
            }

            func requestNextWindow(_ s: inout State) -> Effect<Action> {
                let received = Set(s.receivedParts.keys)
                let req = Resource.nextWindowRequest(
                    receivedIndices: received, hashmap: s.advertisement?.hashmap ?? Data(),
                    height: s.consecutiveCompletedHeight, window: s.window.window,
                    partCount: Int(s.expectedParts))
                s.outstanding = Set(req.indices)
                let payload = Data([0x00]) + s.resourceHash + req.mapHashes
                let linkID = s.linkID
                let interfaceID = s.interfaceID
                let sessionKey = s.sessionKey
                let watchdog = armReceiverWatchdog(s)
                let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                               destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                               destinationHash: linkID, transportId: nil,
                               payload: Link.encrypt(payload, sessionKey: sessionKey))
                guard let raw = try? p.packed() else { return .none }
                return .merge(.send(.delegate(.transmit(interfaceID, raw))), watchdog)
            }

            switch action {
            case .advertise:
                guard state.role == .sender, state.status == .idle, let adv = state.advertisement,
                      let raw = linkPacket(.data, .resourceAdvertisement,
                                           Link.encrypt(adv.pack(), sessionKey: state.sessionKey))
                else { return .none }
                state.status = .advertised
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), armSenderWatchdog(state))

            case let .accept(data):
                guard state.role == .receiver, state.status == .idle,
                      let packet = Packet(raw: data), packet.packetType == .data,
                      packet.context == .resourceAdvertisement,
                      let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                      let adv = ResourceAdvertisement.unpack(plain)
                else { return .none }
                state.resourceHash = adv.hash
                state.randomHash = adv.randomHash
                state.expectedParts = adv.numberOfParts
                state.advertisement = adv
                state.window = ResourceWindow()
                state.consecutiveCompletedHeight = -1
                state.retriesLeft = Const.maxRetries
                state.status = .requesting
                return requestNextWindow(&state)

            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                switch (state.role, packet.packetType, packet.context) {
                case (.sender, .data, .resourceRequest):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey) else { return .none }
                    let p = Data(plain)
                    guard p.count >= 33, p.first == 0x00,
                          Data(p[(p.startIndex + 1)..<(p.startIndex + 33)]) == state.resourceHash
                    else { return .none }
                    state.status = .transferring
                    state.retriesLeft = Const.maxRetries
                    let reqHashes = Data(p.dropFirst(33))
                    var effects: [Effect<Action>] = []
                    var i = reqHashes.startIndex
                    while i + 4 <= reqHashes.endIndex {
                        let mh = Data(reqHashes[i..<(i + 4)])
                        if let idx = state.partMapHashes.firstIndex(of: mh),
                           let raw = linkPacket(.data, .resource, state.parts[idx]) {
                            state.sentIndices.insert(idx)
                            effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                        }
                        i += 4
                    }
                    if state.sentIndices.count == state.parts.count {
                        state.status = .awaitingProof
                    }
                    effects.append(armSenderWatchdog(state))
                    return .merge(effects)

                case (.sender, .proof, .resourceProof):
                    if Resource.validateProof(proofData: packet.payload, expectedProof: state.expectedProof) {
                        state.status = .complete
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.concluded)))
                    }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))

                case (.receiver, .data, .resource):
                    guard state.status == .requesting || state.status == .transferring,
                          let adv = state.advertisement else { return .none }
                    let chunk = packet.payload
                    let mh = Resource.mapHash(chunk: chunk, randomHash: state.randomHash)
                    let m = Data(adv.hashmap)
                    var index: Int? = nil
                    var gi = 0
                    var j = m.startIndex
                    while j + 4 <= m.endIndex {
                        if Data(m[j..<(j + 4)]) == mh { index = gi; break }
                        gi += 1; j += 4
                    }
                    guard let idx = index, state.receivedParts[idx] == nil else { return .none }
                    state.receivedParts[idx] = chunk
                    state.outstanding.remove(idx)
                    state.status = .transferring
                    if !state.receivedFirstPart {
                        state.receivedFirstPart = true
                        state.partTimeoutFactor = Const.partTimeoutFactorAfterRTT
                    }
                    while state.receivedParts[state.consecutiveCompletedHeight + 1] != nil {
                        state.consecutiveCompletedHeight += 1
                    }
                    guard state.outstanding.isEmpty else { return armReceiverWatchdog(state) }
                    // round complete
                    if state.receivedParts.count < Int(state.expectedParts) {
                        state.window = state.window.grown()
                        state.retriesLeft = Const.maxRetries
                        return requestNextWindow(&state)
                    }
                    // all parts in: assemble + verify + prove (cancel the watchdog)
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let out = Resource.assemble(parts: ordered, sessionKey: state.sessionKey),
                          Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                    }
                    state.status = .complete
                    let proof = Resource.proofData(data: out, hash: state.resourceHash)
                    guard let praw = linkPacket(.proof, .resourceProof, proof)
                    else { return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.received(out)))) }
                    return .merge(.cancel(id: CancelID.watchdog),
                                  .send(.delegate(.transmit(state.interfaceID, praw))),
                                  .send(.delegate(.received(out))))

                default:
                    return .none
                }

            case .receiverDeadline:
                guard state.role == .receiver,
                      state.status == .requesting || state.status == .transferring else { return .none }
                guard state.retriesLeft > 0 else {
                    state.status = .failed
                    let rcl = linkPacket(.data, .resourceReceiverCancel,
                                         Link.encrypt(state.resourceHash, sessionKey: state.sessionKey))
                    return .merge(.cancel(id: CancelID.watchdog),
                                  rcl.map { Effect.send(.delegate(.transmit(state.interfaceID, $0))) } ?? .none,
                                  .send(.delegate(.failed)))
                }
                state.window = state.window.shrunk()
                state.retriesLeft -= 1
                return requestNextWindow(&state)

            case .senderDeadline:
                guard state.role == .sender else { return .none }
                switch state.status {
                case .advertised:
                    guard state.advRetriesLeft > 0, let adv = state.advertisement,
                          let raw = linkPacket(.data, .resourceAdvertisement,
                                               Link.encrypt(adv.pack(), sessionKey: state.sessionKey))
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), senderCancel(state), .send(.delegate(.failed)))
                    }
                    state.advRetriesLeft -= 1
                    return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), armSenderWatchdog(state))
                case .transferring:
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), senderCancel(state), .send(.delegate(.failed)))
                case .awaitingProof:
                    guard state.proofRetriesLeft > 0 else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), senderCancel(state), .send(.delegate(.failed)))
                    }
                    state.proofRetriesLeft -= 1
                    return armSenderWatchdog(state)
                default:
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
