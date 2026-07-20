import Foundation
import ComposableArchitecture
import ReTiCA

/// A single-segment Reticulum Resource transfer (one instance per resource) as a TCA feature.
/// Interface-agnostic: raw resource-packet bytes arrive via `advertise`/`accept`/`received`;
/// outbound bytes leave via `delegate(.transmit)`. Uses the pure `Resource` primitives + the
/// link's session key. Single-window: the receiver requests all parts at once.
@Reducer
public struct ResourceTransfer {
    public enum Role: Equatable, Sendable { case sender, receiver }
    public enum Status: Equatable, Sendable { case idle, advertised, requesting, transferring, complete, failed }

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

        /// Sender: build the resource from `data` over the link's session key.
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, id: UUID = UUID()) {
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
        }

        /// Receiver: accept an inbound resource on the given link.
        public init(receivingOn linkID: Data, sessionKey: Data, interfaceID: InterfaceID, id: UUID = UUID()) {
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
        }
    }

    public enum Action: Equatable {
        case advertise
        case accept(Data)
        case received(Data)
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(Data)
            case concluded
            case failed
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            func linkPacket(_ type: PacketType, _ context: PacketContext, _ payload: Data) -> Data? {
                let p = Packet(headerType: .header1, packetType: type, transportType: .broadcast,
                               destinationType: .link, context: context, contextFlag: false, hops: 0,
                               destinationHash: state.linkID, transportId: nil, payload: payload)
                return try? p.packed()
            }

            switch action {
            case .advertise:
                guard state.role == .sender, state.status == .idle, let adv = state.advertisement,
                      let raw = linkPacket(.data, .resourceAdvertisement,
                                           Link.encrypt(adv.pack(), sessionKey: state.sessionKey))
                else { return .none }
                state.status = .advertised
                return .send(.delegate(.transmit(state.interfaceID, raw)))

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
                state.status = .requesting
                let request = Data([0x00]) + adv.hash + adv.hashmap
                guard let raw = linkPacket(.data, .resourceRequest,
                                           Link.encrypt(request, sessionKey: state.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))

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
                    let reqHashes = Data(p.dropFirst(33))
                    var effects: [Effect<Action>] = []
                    var i = reqHashes.startIndex
                    while i + 4 <= reqHashes.endIndex {
                        let mh = Data(reqHashes[i..<(i + 4)])
                        if let idx = state.partMapHashes.firstIndex(of: mh),
                           let raw = linkPacket(.data, .resource, state.parts[idx]) {
                            effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                        }
                        i += 4
                    }
                    return .merge(effects)

                case (.sender, .proof, .resourceProof):
                    if Resource.validateProof(proofData: packet.payload, expectedProof: state.expectedProof) {
                        state.status = .complete
                        return .send(.delegate(.concluded))
                    }
                    state.status = .failed
                    return .send(.delegate(.failed))

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
                    state.status = .transferring
                    guard state.receivedParts.count == Int(state.expectedParts) else { return .none }
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let out = Resource.assemble(parts: ordered, sessionKey: state.sessionKey),
                          Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
                    else { state.status = .failed; return .send(.delegate(.failed)) }
                    state.status = .complete
                    let proof = Resource.proofData(data: out, hash: state.resourceHash)
                    guard let praw = linkPacket(.proof, .resourceProof, proof)
                    else { return .send(.delegate(.received(out))) }
                    return .merge(.send(.delegate(.transmit(state.interfaceID, praw))),
                                  .send(.delegate(.received(out))))

                default:
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
