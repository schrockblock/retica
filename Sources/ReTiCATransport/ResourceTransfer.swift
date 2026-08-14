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
        // hashmap-update (receiver)
        public var knownHashmap: Data
        public var hashmapHeight: Int
        public var waitingForHMU: Bool

        /// Sender: build the resource from `data` over the link's session key.
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, requestID: Data? = nil, isResponse: Bool = false,
                    segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1, originalHash: Data? = nil,
                    totalDataSize: UInt64? = nil, rtt: Duration = .seconds(1), id: UUID = UUID()) {
            self.id = id
            self.role = .sender
            self.status = .idle
            self.interfaceID = interfaceID
            self.linkID = linkID
            self.sessionKey = sessionKey
            self.randomHash = randomHash
            // Compress before encryption; use the compressed payload only when it is actually smaller
            // (matches RNS). The resource hash and dataSize stay over the ORIGINAL data.
            let compressed = Bzip2.compress(data)
            let didCompress = (compressed?.count ?? .max) < data.count
            let payload = didCompress ? compressed! : data
            let stream = Resource.buildStream(data: payload, prefix: prefix, sessionKey: sessionKey)
            let chunks = Resource.parts(stream: stream, sdu: sdu)
            let mapHashes = chunks.map { Resource.mapHash(chunk: $0, randomHash: randomHash) }
            let h = Resource.resourceHash(data: data, randomHash: randomHash)
            self.parts = chunks
            self.partMapHashes = mapHashes
            self.resourceHash = h
            self.expectedProof = Resource.expectedProof(data: data, hash: h)
            self.expectedParts = UInt64(chunks.count)
            self.receivedParts = [:]
            let advFlags: UInt8 = 0x01 | (didCompress ? 0x02 : 0) | (totalSegments > 1 ? 0x04 : 0)
                                       | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)
            self.advertisement = ResourceAdvertisement(
                transferSize: UInt64(stream.count), dataSize: totalDataSize ?? UInt64(data.count),
                numberOfParts: UInt64(chunks.count), hash: h, randomHash: randomHash,
                originalHash: originalHash ?? h,
                segmentIndex: segmentIndex, totalSegments: totalSegments, requestID: requestID, flags: advFlags,
                hashmap: mapHashes.prefix(Resource.hashmapMaxLen).reduce(Data()) { $0 + $1 })
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
            self.knownHashmap = Data()
            self.hashmapHeight = 0
            self.waitingForHMU = false
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
            self.knownHashmap = Data()
            self.hashmapHeight = 0
            self.waitingForHMU = false
        }
    }

    public enum Action: Equatable {
        case advertise
        case accept(Data)
        case received(Data)
        case receiverDeadline
        case senderDeadline
        case cancel
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
                if s.waitingForHMU { return armReceiverWatchdog(s) }   // await the HMU; don't spam REQs
                let received = Set(s.receivedParts.keys)
                let req = Resource.nextWindowRequest(
                    receivedIndices: received, hashmap: s.knownHashmap,
                    height: s.consecutiveCompletedHeight, window: s.window.window,
                    partCount: Int(s.expectedParts))
                s.outstanding = Set(req.indices)
                var payload: Data
                if req.exhausted, s.hashmapHeight > 0 {
                    let last = Data(s.knownHashmap.suffix(Resource.mapHashLength))   // knownHashmap[hashmapHeight-1]
                    payload = Data([0xFF]) + last + s.resourceHash + req.mapHashes
                    s.waitingForHMU = true
                } else {
                    payload = Data([0x00]) + s.resourceHash + req.mapHashes
                }
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
                // `n` is a raw UInt64 off the wire and unpack's magnitude gate bounds only `t`.
                // Every downstream use is `Int(state.expectedParts)`, which TRAPS above Int.max —
                // clamp once here so no use site can. Identity for any legitimate part count.
                state.expectedParts = min(adv.numberOfParts, UInt64(Int.max))
                state.advertisement = adv
                state.knownHashmap = Data(adv.hashmap)
                state.hashmapHeight = adv.hashmap.count / Resource.mapHashLength
                state.waitingForHMU = false
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
                    guard let flag = p.first else { return .none }
                    let wantsHMU = flag == 0xFF
                    let pad = wantsHMU ? 1 + Resource.mapHashLength : 1      // 5 or 1
                    guard p.count >= pad + 32,
                          Data(p[(p.startIndex + pad)..<(p.startIndex + pad + 32)]) == state.resourceHash
                    else { return .none }
                    state.status = .transferring
                    state.retriesLeft = Const.maxRetries
                    let reqHashes = Data(p.dropFirst(pad + 32))
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
                    if wantsHMU {
                        let lastMapHash = Data(p[(p.startIndex + 1)..<(p.startIndex + 1 + Resource.mapHashLength)])
                        if let li = state.partMapHashes.firstIndex(of: lastMapHash) {
                            let partIndex = li + 1
                            if partIndex % Resource.hashmapMaxLen != 0 {
                                // sequencing error → cancel the transfer (matches RNS)
                                state.status = .failed
                                let icl = linkPacket(.data, .resourceInitiatorCancel,
                                                     Link.encrypt(state.resourceHash, sessionKey: state.sessionKey))
                                return .merge(.cancel(id: CancelID.watchdog),
                                              icl.map { Effect.send(.delegate(.transmit(state.interfaceID, $0))) } ?? .none,
                                              .send(.delegate(.failed)))
                            }
                            let chunk = partIndex / Resource.hashmapMaxLen
                            let lo = chunk * Resource.hashmapMaxLen
                            let hi = min((chunk + 1) * Resource.hashmapMaxLen, state.partMapHashes.count)
                            let chunkBytes = state.partMapHashes[lo..<hi].reduce(Data()) { $0 + $1 }
                            let hmu = state.resourceHash + MsgPack.encode(.array([.uint(UInt64(chunk)), .bin(chunkBytes)]))
                            if let raw = linkPacket(.data, .resourceHashmapUpdate,
                                                    Link.encrypt(hmu, sessionKey: state.sessionKey)) {
                                effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                            }
                        }
                    }
                    if state.sentIndices.count == state.parts.count {
                        state.status = .awaitingProof
                    }
                    effects.append(armSenderWatchdog(state))
                    return .merge(effects)

                case (.sender, .proof, .resourceProof):
                    // A proof that does not validate is IGNORED, never destructive. Resource
                    // proofs are unencrypted by reference design (`Packet.pack` has a branch
                    // dedicated to `RESOURCE_PRF`), so nothing here is authenticated — the
                    // ownership routing in `LinkSession` keys on the resource hash, which is a
                    // SECRET carried in an encrypted advertisement, not an authenticator.
                    // Failing on a mismatch therefore made a leaked hash into a kill primitive,
                    // and it is how one junk packet aborted a transfer.
                    //
                    // Reference `Resource.validate_proof` has no else branch: the resource keeps
                    // its status and the sender watchdog terminates it.
                    guard Resource.validateProof(proofData: packet.payload,
                                                 expectedProof: state.expectedProof)
                    else { return .none }
                    state.status = .complete
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.concluded)))

                case (.receiver, .data, .resource):
                    guard state.status == .requesting || state.status == .transferring,
                          let adv = state.advertisement else { return .none }
                    let chunk = packet.payload
                    let mh = Resource.mapHash(chunk: chunk, randomHash: state.randomHash)
                    let m = Data(state.knownHashmap)
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
                    // all parts in: assemble, decompress if flagged, verify + prove (cancel the watchdog)
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let payload = Resource.assemble(parts: ordered, sessionKey: state.sessionKey)
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                    }
                    let out: Data
                    if adv.isCompressed {
                        // `adv.dataSize` (`d`) is a raw UInt64 off the wire, and unpack's magnitude gate
                        // bounds only `t` — so a plain `Int(adv.dataSize)` here would TRAP above Int.max,
                        // before Bzip2.decompress's own ceiling could ever reject it. Stay in UInt64 until
                        // the value is provably small.
                        let segmentExpectedSize: Int
                        if adv.isSplit {
                            // `d` is the WHOLE object's size for a split resource, and legitimately
                            // exceeds one segment. This segment holds at most maxEfficientSize bytes
                            // uncompressed, so that — not `d` — is what bounds the buffer.
                            segmentExpectedSize = Int(min(adv.dataSize, UInt64(LinkSession.maxEfficientSize)))
                        } else {
                            // `d` is this segment's own size. Above the auto-compress ceiling it is not
                            // a resource we could have produced, so fail rather than clamp-and-truncate.
                            guard adv.dataSize <= UInt64(Resource.autoCompressMaxSize) else {
                                state.status = .failed
                                return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                            }
                            segmentExpectedSize = Int(adv.dataSize)
                        }
                        guard let decompressed = Bzip2.decompress(payload, expectedSize: segmentExpectedSize)
                        else {
                            state.status = .failed
                            return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                        }
                        out = decompressed
                    } else {
                        out = payload
                    }
                    guard Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
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

                case (.receiver, .data, .resourceInitiatorCancel):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          Data(plain) == state.resourceHash else { return .none }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))

                case (.sender, .data, .resourceReceiverCancel):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          Data(plain) == state.resourceHash else { return .none }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))

                case (.receiver, .data, .resourceHashmapUpdate):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey) else { return .none }
                    let p = Data(plain)
                    guard p.count >= 32,
                          Data(p[p.startIndex..<(p.startIndex + 32)]) == state.resourceHash else { return .none }
                    guard case let .array(items)? = MsgPack.decodeValue(Data(p.dropFirst(32))),
                          items.count == 2,
                          case let .uint(chunkIndex) = items[0],
                          case let .bin(chunkBytes) = items[1] else { return .none }
                    let offset = Int(chunkIndex) * Resource.hashmapMaxLen * Resource.mapHashLength
                    guard offset == state.knownHashmap.count else { return .none }   // must extend contiguously
                    state.knownHashmap.append(chunkBytes)
                    state.hashmapHeight = state.knownHashmap.count / Resource.mapHashLength
                    state.waitingForHMU = false
                    return requestNextWindow(&state)

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
                state.waitingForHMU = false
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

            case .cancel:
                guard state.status != .complete, state.status != .failed else { return .none }
                let context: PacketContext = state.role == .sender ? .resourceInitiatorCancel : .resourceReceiverCancel
                state.status = .failed
                let cancel = linkPacket(.data, context,
                                        Link.encrypt(state.resourceHash, sessionKey: state.sessionKey))
                return .merge(.cancel(id: CancelID.watchdog),
                              cancel.map { Effect.send(.delegate(.transmit(state.interfaceID, $0))) } ?? .none,
                              .send(.delegate(.failed)))

            case .delegate:
                return .none
            }
        }
    }
}
