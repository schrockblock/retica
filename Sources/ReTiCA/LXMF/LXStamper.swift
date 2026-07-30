import Foundation

/// LXMF proof-of-work stamps (LXMF-5b). A stamp is a 32-byte value whose full_hash(workblock ‖ stamp)
/// has at least `targetCost` leading zero bits, where the workblock is deterministically expanded from
/// the material (message_id). Validation is deterministic; generation is a brute-force search. Mirrors
/// lxmf 1.1.0 LXStamper (stamp_workblock / stamp_valid / stamp_value / generate_stamp).
public enum LXStamper {
    public static let workblockExpandRounds = 3000     // RNS WORKBLOCK_EXPAND_ROUNDS
    public static let stampSize = 32                   // RNS STAMP_SIZE (HASHLENGTH/8)

    /// Deterministic ~256*expandRounds-byte workblock: concat of hkdf(256, ikm=material,
    /// salt=full_hash(material ‖ msgpack(n))) for n in 0..<expandRounds.
    public static func stampWorkblock(material: Data, expandRounds: Int = workblockExpandRounds) -> Data {
        var wb = Data()
        for n in 0..<expandRounds {
            let salt = Crypto.fullHash(material + MsgPack.encode(.uint(UInt64(n))))
            wb += Crypto.hkdf(length: 256, derivedFrom: material, salt: salt, context: nil)
        }
        return wb
    }

    /// True iff full_hash(workblock ‖ stamp) has >= targetCost leading zero bits.
    public static func stampValid(stamp: Data, targetCost: Int, workblock: Data) -> Bool {
        stampValue(workblock: workblock, stamp: stamp) >= targetCost
    }

    /// Count of leading zero bits of full_hash(workblock ‖ stamp).
    public static func stampValue(workblock: Data, stamp: Data) -> Int {
        let digest = Crypto.fullHash(workblock + stamp)
        var value = 0
        for byte in digest {
            if byte == 0 { value += 8; continue }
            value += byte.leadingZeroBitCount
            break
        }
        return value
    }

    /// Search random 32-byte stamps until one is valid for `targetCost` over `messageId`'s workblock.
    public static func generateStamp(messageId: Data, targetCost: Int) -> Data {
        let wb = stampWorkblock(material: messageId)
        while true {
            let s = SecureRandom.bytes(stampSize)
            if stampValid(stamp: s, targetCost: targetCost, workblock: wb) { return s }
        }
    }
}
