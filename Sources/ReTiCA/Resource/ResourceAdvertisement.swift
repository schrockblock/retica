import Foundation

/// A Reticulum resource advertisement (`RESOURCE_ADV` payload): a MessagePack dictionary with keys
/// `t,d,n,h,r,o,i,l,q,f,m` (in that order, matching RNS `ResourceAdvertisement.pack`).
public struct ResourceAdvertisement: Equatable {
    public var transferSize: UInt64    // t — encrypted transfer stream size
    public var dataSize: UInt64        // d — original (uncompressed) data size
    public var numberOfParts: UInt64   // n
    public var hash: Data              // h
    public var randomHash: Data        // r
    public var originalHash: Data      // o — first-segment hash (== h for a single segment)
    public var segmentIndex: UInt64    // i
    public var totalSegments: UInt64   // l
    public var requestID: Data?        // q
    public var flags: UInt8            // f
    public var hashmap: Data           // m

    public init(transferSize: UInt64, dataSize: UInt64, numberOfParts: UInt64, hash: Data,
                randomHash: Data, originalHash: Data, segmentIndex: UInt64, totalSegments: UInt64,
                requestID: Data?, flags: UInt8, hashmap: Data) {
        self.transferSize = transferSize; self.dataSize = dataSize; self.numberOfParts = numberOfParts
        self.hash = hash; self.randomHash = randomHash; self.originalHash = originalHash
        self.segmentIndex = segmentIndex; self.totalSegments = totalSegments
        self.requestID = requestID; self.flags = flags; self.hashmap = hashmap
    }

    public func pack() -> Data {
        let q: MsgPackValue = requestID.map { .bin($0) } ?? .null
        return MsgPack.encode(.map([
            .init("t", .uint(transferSize)),
            .init("d", .uint(dataSize)),
            .init("n", .uint(numberOfParts)),
            .init("h", .bin(hash)),
            .init("r", .bin(randomHash)),
            .init("o", .bin(originalHash)),
            .init("i", .uint(segmentIndex)),
            .init("l", .uint(totalSegments)),
            .init("q", q),
            .init("f", .uint(UInt64(flags))),
            .init("m", .bin(hashmap)),
        ]))
    }

    public static func unpack(_ data: Data) -> ResourceAdvertisement? {
        guard case let .map(pairs)? = MsgPack.decodeValue(data) else { return nil }
        var dict: [String: MsgPackValue] = [:]
        for p in pairs { dict[p.key] = p.value }
        func uint(_ k: String) -> UInt64? { if case let .uint(x)? = dict[k] { return x } else { return nil } }
        func bin(_ k: String) -> Data? { if case let .bin(x)? = dict[k] { return x } else { return nil } }
        guard let t = uint("t"), let d = uint("d"), let n = uint("n"),
              let h = bin("h"), let r = bin("r"), let o = bin("o"),
              let i = uint("i"), let l = uint("l"), let f = uint("f"), let m = bin("m")
        else { return nil }
        let q: Data?
        switch dict["q"] {
        case .some(.bin(let x)): q = x
        case .some(.null), .none: q = nil
        default: return nil
        }
        return ResourceAdvertisement(transferSize: t, dataSize: d, numberOfParts: n, hash: h,
                                     randomHash: r, originalHash: o, segmentIndex: i, totalSegments: l,
                                     requestID: q, flags: UInt8(truncatingIfNeeded: f), hashmap: m)
    }

    public var isEncrypted: Bool { flags & 0x01 == 0x01 }
    public var isCompressed: Bool { (flags >> 1) & 0x01 == 0x01 }
    public var isSplit: Bool { (flags >> 2) & 0x01 == 0x01 }
    public var isRequest: Bool { (flags >> 3) & 0x01 == 0x01 }
    public var isResponse: Bool { (flags >> 4) & 0x01 == 0x01 }
    public var hasMetadata: Bool { (flags >> 5) & 0x01 == 0x01 }
}
