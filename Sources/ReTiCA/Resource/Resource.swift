import Foundation

/// Pure content primitives of a Reticulum Resource (single-segment, uncompressed). Resources are
/// Link-coupled: the whole data stream is encrypted with the link's session key (`Token`) before
/// being split into parts, so the encryption primitives take the session key as a parameter.
public enum Resource {
    public static let mapHashLength = 4
    public static let randomHashSize = 4

    /// Resource hash: `full_hash(data ‖ r)` over the original (pre-encryption) data.
    public static func resourceHash(data: Data, randomHash: Data) -> Data {
        Crypto.fullHash(data + randomHash)
    }

    /// Encrypted transfer stream: `Token(key).encrypt(prefix(4) ‖ data)`. Empty on bad key.
    public static func buildStream(data: Data, prefix: Data, sessionKey: Data) -> Data {
        guard let token = try? Token(key: sessionKey) else { return Data() }
        return token.encrypt(prefix + data)
    }

    /// Split an encrypted stream into `sdu`-sized ciphertext chunks (the resource parts).
    public static func parts(stream: Data, sdu: Int) -> [Data] {
        guard sdu > 0 else { return [] }
        let s = Data(stream)
        var out: [Data] = []
        var i = s.startIndex
        while i < s.endIndex {
            let end = s.index(i, offsetBy: sdu, limitedBy: s.endIndex) ?? s.endIndex
            out.append(Data(s[i..<end]))
            i = end
        }
        return out
    }

    /// Map hash of a part: `full_hash(chunk ‖ r)[:4]`.
    public static func mapHash(chunk: Data, randomHash: Data) -> Data {
        Data(Crypto.fullHash(chunk + randomHash).prefix(mapHashLength))
    }

    /// The concatenated map hashes for all parts.
    public static func hashmap(parts: [Data], randomHash: Data) -> Data {
        var m = Data()
        for p in parts { m.append(mapHash(chunk: p, randomHash: randomHash)) }
        return m
    }

    /// Sender-side expected proof value: `full_hash(data ‖ h)`.
    public static func expectedProof(data: Data, hash: Data) -> Data {
        Crypto.fullHash(data + hash)
    }

    /// Reassemble parts back to the original data: `decrypt(join(parts))` then drop the 4-byte prefix.
    public static func assemble(parts: [Data], sessionKey: Data) -> Data? {
        guard let token = try? Token(key: sessionKey) else { return nil }
        var stream = Data()
        for p in parts { stream.append(p) }
        guard let plain = try? token.decrypt(stream), plain.count >= randomHashSize else { return nil }
        return Data(plain.dropFirst(randomHashSize))
    }

    /// Verify assembled data against the advertised hash: `full_hash(data ‖ r) == h`.
    public static func verify(data: Data, randomHash: Data, hash: Data) -> Bool {
        Crypto.fullHash(data + randomHash) == hash
    }

    /// Receiver-side proof data sent back to the sender: `h ‖ full_hash(data ‖ h)` (64 bytes).
    public static func proofData(data: Data, hash: Data) -> Data {
        Data(hash) + Crypto.fullHash(data + hash)
    }

    /// Sender validates a received proof: 64 bytes and its trailing 32 equal the expected proof.
    public static func validateProof(proofData: Data, expectedProof: Data) -> Bool {
        let d = Data(proofData)
        guard d.count == 64 else { return false }
        return Data(d.suffix(32)) == expectedProof
    }

    /// Select the next window of still-missing parts to request. Scans the `window` slots after
    /// `height` (bounded by `partCount`), returning the indices not present in `receivedIndices`
    /// and their concatenated 4-byte map hashes sliced from `hashmap`. Index-safe.
    public static func nextWindowRequest(
        receivedIndices: Set<Int>, hashmap: Data, height: Int, window: Int, partCount: Int
    ) -> (indices: [Int], mapHashes: Data) {
        let m = Data(hashmap)
        var indices: [Int] = []
        var mapHashes = Data()
        var pn = height + 1
        let searchEnd = min(height + 1 + window, partCount)
        while pn < searchEnd {
            if !receivedIndices.contains(pn) {
                let start = m.startIndex + pn * mapHashLength
                let end = start + mapHashLength
                guard end <= m.endIndex else { break }
                indices.append(pn)
                mapHashes.append(Data(m[start..<end]))
            }
            pn += 1
        }
        return (indices, mapHashes)
    }
}
