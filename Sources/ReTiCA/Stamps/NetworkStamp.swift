import Foundation
import CryptoKit

/// RNS 1.6.0 network stamps (RNS/Stamps.py): proof of work attached to announces, path requests and
/// link requests. This is the arithmetic only. Costs are fractional, held as 8-bit fixed point
/// (`fixedPoint(cost:)`), and a stamp is valid when `full_hash(material ‖ stamp)`, read as a big-endian
/// 256-bit integer, is at or below `target(fixedPoint:)`.
///
/// Network stamps use `expand_rounds=0`, so the workblock is the `material` itself: there is no HKDF
/// expansion, and one validation is one SHA-256.
///
/// **Hash rates** (Mac figures only, release build, one task, measured as expected rounds over elapsed
/// time across 60 and 100 searches of the real `generate` / `generateKey` loops, so statistical, about
/// +/-15%; a phone will differ):
///   * `generate`    (random 14-byte stamp, one SHA-256 per round): about 790,000 rounds/s
///   * `generateKey` (fresh X25519 key per round, one SHA-256 per round): about 14,000 rounds/s
/// So a cost-15.8 stamp (about 57,000 rounds) takes well under a second, cost 23.5 about 15 s, while a
/// cost-12.5 key takes about 0.4 s and a cost-23.5 key would take about 15 minutes.
///
/// Every search is unbounded (about 2^cost rounds), so each one stops and returns nil as soon as the
/// enclosing `Task` is cancelled, and yields every `searchYieldInterval` rounds so the cancellation can
/// be delivered. See `LXStamper.search`, which this mirrors. Callers bound the cost BEFORE searching:
/// `generate*` clamp to `stampCostCap` but do not enforce any smaller policy cap.
public enum NetworkStamp {
    // MARK: Wire values

    /// RNS.Identity.STAMPLENGTH, bytes.
    public static let stampLength = 14
    /// RNS.Identity.EXTPAYLOADMARKER, never used at msgpack object boundaries.
    public static let extensionMarker: UInt8 = 0xC1
    /// RNS.Identity.EXTPAYLOADLENGTH: the announce extension is marker, flags byte, stamp, then the link
    /// cost as two bytes, fractional byte first and the anchor (integer part, reserved flag in the MSB)
    /// last (Destination.py:354).
    public static let extensionLength = 2 + stampLength + 2

    // MARK: Defaults and caps

    /// Stamp cost a destination demands of announces it receives (RNS Transport.DESTINATION_COST).
    public static let defaultDestinationCost = 23.5
    /// Stamp value a destination attaches to its own announces (RNS Transport.DESTINATION_VALUE).
    public static let defaultDestinationValue = 25.0
    /// Cost demanded of path requests (RNS Transport.PR_COST).
    public static let defaultPathRequestCost = 15.8
    /// Value attached to our own path requests (RNS Transport.PR_VALUE).
    public static let defaultPathRequestValue = 15.8
    /// Cost demanded of link requests (RNS Transport.LR_COST).
    public static let defaultLinkRequestCost = 12.5
    /// Hard ceiling for any cost, and for fixed-point clamping (RNS Transport.STAMP_COST_CAP).
    public static let stampCostCap = 100
    /// Ceiling on a link-request stamp cost we will pay (RNS Link.LINK_COST_CAP).
    public static let linkCostCap = 40
    /// Seconds allowed to produce a link-request stamp.
    public static let linkStampTimeout: TimeInterval = 15
    /// Seconds allowed to produce a path-request stamp.
    public static let pathStampTimeout: TimeInterval = 15

    // MARK: Fixed point

    private static let costFixedPointBits = 8
    private static let costFixedPointScale = 1 << costFixedPointBits   // COST_FP
    private static let mantissaBits = 33
    private static let maxFixedPoint = stampCostCap * costFixedPointScale

    /// Cost in 1/256 steps, rounded half up and clamped to 0...`stampCostCap`*256 (RNS cost_to_fp).
    /// NaN counts as 0. Infinities and huge values clamp rather than trap: costs arrive off the wire.
    public static func fixedPoint(cost: Double) -> Int {
        if cost.isNaN { return 0 }
        let v = (cost * Double(costFixedPointScale) + 0.5).rounded(.down)
        let clamped = min(max(v, 0), Double(maxFixedPoint))
        return Int(clamped)
    }

    /// A cost from its two big-endian fixed-point bytes, `((b[0] << 8) | b[1]) / 256` (RNS
    /// cost_from_bytes). Nil unless exactly two bytes. Not clamped: up to 255.996, as the reference reads.
    public static func cost(fromBytes bytes: Data) -> Double? {
        guard bytes.count == 2 else { return nil }
        let high = Int(bytes[bytes.startIndex])
        let low = Int(bytes[bytes.startIndex + 1])
        return Double(high << costFixedPointBits | low) / Double(costFixedPointScale)
    }

    /// The 32-byte big-endian hash threshold for a fixed-point cost (RNS target_from_fp). Out-of-range
    /// input clamps to 0...`stampCostCap`*256.
    ///
    /// At fixed point 0 the reference target is 2^256, which does not fit 32 bytes. Every hash is below
    /// it, so it is returned saturated as 0xFF x 32, which accepts exactly the same hashes.
    public static func target(fixedPoint: Int) -> Data {
        let fp = min(max(fixedPoint, 0), maxFixedPoint)
        let remainder = 256 * costFixedPointScale - fp
        let exponent = remainder / costFixedPointScale        // i
        let fraction = remainder % costFixedPointScale        // f
        // (TAB[f] << i) >> MANTISSA_BITS: bit b of TAB[f] lands at bit b + i - 33.
        let shift = exponent - mantissaBits
        var out = [UInt8](repeating: 0, count: 32)
        let mantissa = tab[fraction]
        for b in 0...mantissaBits {
            guard mantissa >> UInt64(b) & 1 == 1 else { continue }
            let p = b + shift
            if p < 0 { continue }
            if p >= 256 { return Data(repeating: 0xFF, count: 32) }
            out[31 - p / 8] |= UInt8(1) << UInt8(p % 8)
        }
        return Data(out)
    }

    /// Stamp value for `stamp` over `material` (RNS stamp_value; reference takes `(workblock, stamp)`).
    /// A real number: the leading-zero count of the hash plus a 1/256-step fraction from its mantissa.
    /// Does not check the stamp's length; callers reject a stamp whose length is not `stampLength`.
    public static func value(stamp: Data, material: Data) -> Double {
        let hash = [UInt8](Crypto.fullHash(material + stamp))
        guard let firstNonZero = hash.firstIndex(where: { $0 != 0 }) else { return 256 }
        let leadingZeros = firstNonZero * 8 + hash[firstNonZero].leadingZeroBitCount
        let bitLength = 256 - leadingZeros
        // Top 34 bits starting at the leading one, zero-padded on the right when fewer remain.
        var mantissa: UInt64 = 0
        for k in 0...mantissaBits {
            let pos = bitLength - 1 - k
            let bit: UInt64 = pos >= 0 ? UInt64(hash[31 - pos / 8] >> UInt8(pos % 8) & 1) : 0
            mantissa = mantissa << 1 | bit
        }
        let climb = tabClimb(mantissa: mantissa)
        let valueFP = ((leadingZeros + 1) << costFixedPointBits) - climb
        return Double(valueFP) / Double(costFixedPointScale)
    }

    /// bisect_right over `tab`: the number of table entries at or below `mantissa`. A mantissa equal to an
    /// entry counts that entry.
    static func tabClimb(mantissa: UInt64) -> Int {
        tab.firstIndex(where: { $0 > mantissa }) ?? tab.count
    }

    /// True when `full_hash(material ‖ stamp)` is at or below the target for `cost` (RNS stamp_valid).
    ///
    /// Does not check the stamp's length: the reference does not either. Callers reject a stamp whose
    /// length is not `stampLength` before asking.
    public static func isValid(stamp: Data, cost: Double, material: Data) -> Bool {
        let target = [UInt8](target(fixedPoint: fixedPoint(cost: cost)))
        return hashMeets(Crypto.fullHash(material + stamp), target: target)
    }

    /// Big-endian `hash <= target`, both 32 bytes.
    static func hashMeets(_ hash: Data, target: [UInt8]) -> Bool {
        var i = 0
        for byte in hash {
            if byte != target[i] { return byte < target[i] }
            i += 1
        }
        return true
    }

    // MARK: Generation

    /// Rounds between yields, as `LXStamper.searchYieldInterval`: bounds how long a search holds its
    /// executor thread before a cancellation gets a turn.
    private static let searchYieldInterval = 32

    /// Search random 14-byte stamps until one is valid for `cost` over `material`. Nil only if the
    /// enclosing `Task` was cancelled first. `cost` clamps like `fixedPoint(cost:)`.
    public static func generate(material: Data, cost: Double) async -> (stamp: Data, value: Double)? {
        let found = await search(material: material, cost: cost) { (SecureRandom.bytes(stampLength), ()) }
        return found.map { ($0.stamp, value(stamp: $0.stamp, material: material)) }
    }

    /// The loop `generate` and `generateKey` share: draw a candidate, hash `material ‖ stamp`, stop at the
    /// first at or below the target for `cost`. Yields every `searchYieldInterval` rounds and returns nil
    /// as soon as the enclosing `Task` is cancelled.
    private static func search<Extra>(
        material: Data, cost: Double, candidate: () -> (stamp: Data, extra: Extra)
    ) async -> (stamp: Data, extra: Extra)? {
        let target = [UInt8](target(fixedPoint: fixedPoint(cost: cost)))
        var round = 0
        while !Task.isCancelled {
            let next = candidate()
            if hashMeets(Crypto.fullHash(material + next.stamp), target: target) { return next }
            round += 1
            if round % searchYieldInterval == 0 { await Task.yield() }
        }
        return nil
    }

    /// Search fresh X25519 keypairs until the public key, used as the stamp, is valid for `cost` over
    /// `material` (RNS generate_stamped_key). Nil only if the enclosing `Task` was cancelled first.
    public static func generateKey(material: Data, cost: Double)
        async -> (privateKey: Data, publicKey: Data, value: Double)? {
        let found = await search(material: material, cost: cost) {
            let key = Curve25519.KeyAgreement.PrivateKey()
            return (key.publicKey.rawRepresentation, key.rawRepresentation)
        }
        return found.map { ($0.extra, $0.stamp, value(stamp: $0.stamp, material: material)) }
    }

    // MARK: Table

    /// TAB[f] = floor(2^33 * 2^(f/256)), f = 0..255. Copied verbatim from RNS/Stamps.py; the reference
    /// says never to compute it, and a test checks its SHA-256 against the reference TAB_DIGEST.
    static let tab: [UInt64] = [
        0x200000000, 0x201635f4b, 0x202c7b53f, 0x2042d0287, 0x2059347ce, 0x206fa85c2,
        0x20862bd0d, 0x209cbee5e, 0x20b361a62, 0x20ca141c7, 0x20e0d653b, 0x20f7a856e,
        0x210e8a30e, 0x21257becc, 0x213c7d958, 0x21538f363, 0x216ab0d9f, 0x2181e28bc,
        0x21992456e, 0x21b076467, 0x21c7d865a, 0x21df4abfb, 0x21f6cd5ff, 0x220e6051a,
        0x222603a02, 0x223db756b, 0x22557b80d, 0x226d5029e, 0x2285355d5, 0x229d2b269,
        0x22b531914, 0x22cd48a8e, 0x22e57078f, 0x22fda90d2, 0x2315f2711, 0x232e4cb06,
        0x2346b7d6d, 0x235f33f02, 0x2377c1080, 0x23905f2a5, 0x23a90e62d, 0x23c1cebd6,
        0x23daa045f, 0x23f383087, 0x240c7710c, 0x24257c6af, 0x243e9322f, 0x2457bb44f,
        0x2470f4dce, 0x248a3ff70, 0x24a39c9f6, 0x24bd0ae23, 0x24d68acbc, 0x24f01c683,
        0x2509bfc3e, 0x252374eb2, 0x253d3bea3, 0x255714cda, 0x2570ffa1b, 0x258afc72e,
        0x25a50b4dc, 0x25bf2c3ec, 0x25d95f527, 0x25f3a4957, 0x260dfc146, 0x262865dbd,
        0x2642e1f89, 0x265d70775, 0x26781164c, 0x2692c4cdc, 0x26ad8abf2, 0x26c86345b,
        0x26e34e6e7, 0x26fe4c463, 0x27195cda0, 0x27348036e, 0x274fb669c, 0x276aff7fd,
        0x27865b862, 0x27a1ca89d, 0x27bd4c982, 0x27d8e1be3, 0x27f48a095, 0x28104586c,
        0x282c1443e, 0x2847f64e1, 0x2863ebb2a, 0x287ff47f0, 0x289c10c0c, 0x28b840854,
        0x28d483da3, 0x28f0dacd1, 0x290d456b8, 0x2929c3c32, 0x294655e1a, 0x2962fbd4d,
        0x297fb5aa6, 0x299c83702, 0x29b96533f, 0x29d65b03b, 0x29f364ed3, 0x2a1082fe8,
        0x2a2db5459, 0x2a4afbd07, 0x2a6856ad3, 0x2a85c5e9e, 0x2aa34994b, 0x2ac0e1bbd,
        0x2ade8e6d6, 0x2afc4fb7c, 0x2b1a25a92, 0x2b38104ff, 0x2b560fba9, 0x2b7423f75,
        0x2b924d14b, 0x2bb08b213, 0x2bcede2b5, 0x2bed4641b, 0x2c0bc372e, 0x2c2a55cd9,
        0x2c48fd607, 0x2c67ba3a3, 0x2c868c699, 0x2ca573fd7, 0x2cc47104a, 0x2ce3838e1,
        0x2d02aba89, 0x2d21e9633, 0x2d413cccf, 0x2d60a5f4e, 0x2d8024ea1, 0x2d9fb9bba,
        0x2dbf6478c, 0x2ddf2530b, 0x2dfefbf2a, 0x2e1ee8cde, 0x2e3eebd1d, 0x2e5f050dd,
        0x2e7f34914, 0x2e9f7a6ba, 0x2ebfd6ac8, 0x2ee049635, 0x2f00d29fb, 0x2f2172715,
        0x2f4228e7d, 0x2f62f612e, 0x2f83da026, 0x2fa4d4c5f, 0x2fc5e66d9, 0x2fe70f092,
        0x30084ea87, 0x3029a55ba, 0x304b13329, 0x306c983d7, 0x308e348c4, 0x30afe82f3,
        0x30d1b3368, 0x30f395b26, 0x31158fb31, 0x3137a148f, 0x3159ca845, 0x317c0b75a,
        0x319e642d6, 0x31c0d4bc1, 0x31e35d322, 0x3205fda05, 0x3228b6172, 0x324b86a75,
        0x326e6f619, 0x32917056b, 0x32b489979, 0x32d7bb34e, 0x32fb053fb, 0x331e67c8f,
        0x3341e2e19, 0x3365769aa, 0x338923054, 0x33ace8329, 0x33d0c633c, 0x33f4bd1a0,
        0x3418ccf6b, 0x343cf5db1, 0x346137d89, 0x348593008, 0x34aa07647, 0x34ce9515e,
        0x34f33c266, 0x3517fca78, 0x353cd6aaf, 0x3561ca426, 0x3586d77fa, 0x35abfe747,
        0x35d13f32b, 0x35f699cc4, 0x361c0e531, 0x36419cd93, 0x366745709, 0x368d082b6,
        0x36b2e51bc, 0x36d8dc53e, 0x36feede5f, 0x372519e44, 0x374b60614, 0x3771c16f3,
        0x37983d209, 0x37bed387e, 0x37e584b7a, 0x380c50c28, 0x383337bb0, 0x385a39b3f,
        0x388156bff, 0x38a88ef1f, 0x38cfe25ca, 0x38f751131, 0x391edb280, 0x394680aea,
        0x396e41b9d, 0x39961e5cd, 0x39be16aab, 0x39e62ab6b, 0x3a0e5a940, 0x3a36a6561,
        0x3a5f0e101, 0x3a8791d59, 0x3ab031b9f, 0x3ad8edd0c, 0x3b01c62d9, 0x3b2abae3f,
        0x3b53cc07b, 0x3b7cf9ac7, 0x3ba643e60, 0x3bcfaac83, 0x3bf92e66f, 0x3c22ced63,
        0x3c4c8c29e, 0x3c7666762, 0x3ca05dcf1, 0x3cca7248c, 0x3cf4a3f78, 0x3d1ef2ef9,
        0x3d495f454, 0x3d73e90cf, 0x3d9e905b1, 0x3dc955443, 0x3df437dcc, 0x3e1f38396,
        0x3e4a566ed, 0x3e759291b, 0x3ea0ecb6d, 0x3ecc64f31, 0x3ef7fb5b3, 0x3f23b0044,
        0x3f4f83033, 0x3f7b746d2, 0x3fa784571, 0x3fd3b2d65,
    ]
}
