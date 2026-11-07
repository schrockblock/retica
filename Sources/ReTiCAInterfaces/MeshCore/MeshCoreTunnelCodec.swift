import Foundation

public enum MeshCoreFrameType: Equatable, Sendable {
    case rnsFragment
    case bindRequest
    case bind
    case other(UInt8)
}

public struct MeshCoreDatagram: Equatable, Sendable {
    public var type: MeshCoreFrameType
    public var canRoute: Bool
    public var src: Data
    public var dst: Data
    public var packetID: UInt16
    public var fragmentIndex: UInt8
    public var fragmentTotal: UInt8
    public var body: Data

    public init(
        type: MeshCoreFrameType, canRoute: Bool, src: Data, dst: Data,
        packetID: UInt16, fragmentIndex: UInt8, fragmentTotal: UInt8, body: Data
    ) {
        self.type = type
        self.canRoute = canRoute
        self.src = src
        self.dst = dst
        self.packetID = packetID
        self.fragmentIndex = fragmentIndex
        self.fragmentTotal = fragmentTotal
        self.body = body
    }
}

public protocol MeshCoreTunnelCodec: Sendable {
    /// Frames `data` into datagrams. Empty means it cannot be framed.
    func split(
        _ data: Data, type: MeshCoreFrameType, src: Data, dst: Data,
        packetID: UInt16, canRoute: Bool
    ) -> [Data]
    func parse(_ datagram: Data) -> MeshCoreDatagram?
}

public struct ScotMeshRawCodec: MeshCoreTunnelCodec, Equatable {
    public static let magic: UInt8 = 0x52
    public static let headerSize = 14
    public static let payloadSize = 148
    public static let maxFragments = 255
    public static let maxDatagram = headerSize + payloadSize
    public static let broadcast = Data(repeating: 0, count: 4)

    private static let prefixSize = 4
    private static let typeMask: UInt8 = 0x0F
    private static let canRouteMask: UInt8 = 0x10

    public init() {}

    public func split(
        _ data: Data, type: MeshCoreFrameType, src: Data, dst: Data,
        packetID: UInt16, canRoute: Bool
    ) -> [Data] {
        let data = Data(data)
        let src = Data(src)
        let dst = Data(dst)
        guard !data.isEmpty,
              src.count == Self.prefixSize, dst.count == Self.prefixSize
        else { return [] }
        let total = (data.count + Self.payloadSize - 1) / Self.payloadSize
        guard total <= Self.maxFragments else { return [] }

        let flags = Self.nibble(for: type) | (canRoute ? Self.canRouteMask : 0)
        var datagrams: [Data] = []
        datagrams.reserveCapacity(total)
        for index in 0..<total {
            let start = data.startIndex + index * Self.payloadSize
            let end = min(start + Self.payloadSize, data.endIndex)
            var datagram = Data()
            datagram.reserveCapacity(Self.headerSize + end - start)
            datagram.append(Self.magic)
            datagram.append(flags)
            datagram.append(src)
            datagram.append(dst)
            datagram.append(UInt8(packetID >> 8))
            datagram.append(UInt8(packetID & 0xFF))
            datagram.append(UInt8(index))
            datagram.append(UInt8(total))
            datagram.append(data[start..<end])
            datagrams.append(datagram)
        }
        return datagrams
    }

    public func parse(_ datagram: Data) -> MeshCoreDatagram? {
        let bytes = Data(datagram)
        guard bytes.count >= Self.headerSize, bytes[0] == Self.magic else { return nil }
        let flags = bytes[1]
        let index = bytes[12]
        let total = bytes[13]
        guard total != 0, index < total else { return nil }
        return MeshCoreDatagram(
            type: Self.frameType(for: flags & Self.typeMask),
            canRoute: flags & Self.canRouteMask != 0,
            src: bytes.subdata(in: 2..<6),
            dst: bytes.subdata(in: 6..<10),
            packetID: UInt16(bytes[10]) << 8 | UInt16(bytes[11]),
            fragmentIndex: index,
            fragmentTotal: total,
            body: bytes.subdata(in: Self.headerSize..<bytes.count)
        )
    }

    private static func nibble(for type: MeshCoreFrameType) -> UInt8 {
        switch type {
        case .rnsFragment: 0
        case .bindRequest: 1
        case .bind: 2
        case .other(let value): value & typeMask
        }
    }

    private static func frameType(for nibble: UInt8) -> MeshCoreFrameType {
        switch nibble {
        case 0: .rnsFragment
        case 1: .bindRequest
        case 2: .bind
        default: .other(nibble)
        }
    }
}

public enum MeshCoreFraming: Equatable, Sendable {
    case scotMeshRaw

    public var codec: any MeshCoreTunnelCodec {
        switch self {
        case .scotMeshRaw: ScotMeshRawCodec()
        }
    }
}
