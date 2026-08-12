import Foundation

/// Pure content primitives of a Reticulum Resource (single-segment, uncompressed). Resources are
/// Link-coupled: the whole data stream is encrypted with the link's session key (`Token`) before
/// being split into parts, so the encryption primitives take the session key as a parameter.
public enum Resource {
    public static let mapHashLength = 4
    public static let randomHashSize = 4
    /// Map hashes that fit in one advertisement / HMU chunk: floor((Link.MDU 431 - 134) / 4) = 74.
    public static let hashmapMaxLen = 74

    /// Reference `AUTO_COMPRESS_MAX_SIZE` (RNS/Resource.py:124) — the largest payload reference
    /// will auto-compress, and the ceiling it enforces when decompressing (RNS/Resource.py:360).
    public static let autoCompressMaxSize = 64 * 1024 * 1024
    /// Ceiling on an advertisement's declared transfer size (`t`).
    ///
    /// Reference rejects `t > MAX_EFFICIENT_SIZE*3` (RNS/Resource.py:1366). It can afford that
    /// tight a bound ONLY because `Resource.__init__` splits EVERY resource at MAX_EFFICIENT_SIZE
    /// (RNS/Resource.py:274-310, reached from Link.py:506/846/852), so no reference advertisement
    /// ever legitimately exceeds it. ReTiCA does not split requests or responses:
    /// `LinkSession.sendRequest`/`sendResponse` hand the whole payload to ONE `ResourceTransfer`
    /// (only `sendResource` segments). A propagation-node mailbox download is therefore served as a
    /// single un-split resource whose `t` is the whole mailbox — up to
    /// `LXMFServiceNode.State.defaultStorageLimitBytes` (32 MiB) — so importing reference's number
    /// made our own receiver reject our own sender.
    ///
    /// The base is corrected rather than the shape: reference bounds `t` at (largest legitimate
    /// single-resource payload) * 3, with the *3 covering encryption/compression expansion. For us
    /// that payload is bounded by `autoCompressMaxSize` — the reference AUTO_COMPRESS_MAX_SIZE that
    /// already gates the receive path's decompression buffer — not by MAX_EFFICIENT_SIZE.
    ///
    /// Safe to loosen: `t` drives NO allocation on the receive path (nothing reads
    /// `transferSize` after unpack). The allocation-bearing wire values are guarded independently
    /// and those guards are untouched — `n` is clamped at accept, `d` is gated against
    /// `autoCompressMaxSize` on the non-split branch, and `Bzip2.decompress` carries its own
    /// `expectedSize` ceiling. This stays a sanity bound, not the load-bearing defence.
    ///
    /// The reference-faithful fix is to split requests/responses like `sendResource` already does;
    /// that is a planned task, and when it lands this can return to `maxEfficientSize * 3`.
    public static let maxAdvertisedTransferSize = autoCompressMaxSize * 3

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
    /// `height` (bounded by `partCount`), returning the missing indices whose map-hash is KNOWN
    /// (present in `hashmap`) and their concatenated 4-byte map hashes. `exhausted` is `true` when the
    /// scan reaches a missing part whose map-hash is not yet in `hashmap` (the receiver must request an
    /// HMU). Index-safe.
    public static func nextWindowRequest(
        receivedIndices: Set<Int>, hashmap: Data, height: Int, window: Int, partCount: Int
    ) -> (indices: [Int], mapHashes: Data, exhausted: Bool) {
        let m = Data(hashmap)
        var indices: [Int] = []
        var mapHashes = Data()
        var exhausted = false
        var pn = height + 1
        let searchEnd = min(height + 1 + window, partCount)
        while pn < searchEnd {
            if !receivedIndices.contains(pn) {
                let start = m.startIndex + pn * mapHashLength
                let end = start + mapHashLength
                if end > m.endIndex { exhausted = true; break }   // map-hash for this missing part not yet known
                indices.append(pn)
                mapHashes.append(Data(m[start..<end]))
            }
            pn += 1
        }
        return (indices, mapHashes, exhausted)
    }
}
