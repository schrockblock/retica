import Foundation

/// LXMF propagation container + transient id (LXMF-4d-1). Pure wire helpers for the store-and-forward
/// format a propagation node stores and serves: `msgpack([timestamp, [lxmf_data…]])`, where each
/// `lxmf_data = destinationHash(16) ‖ destination-encrypted(sourceHash‖signature‖payload)` and
/// `transient_id = full_hash(lxmf_data)` (RNS Identity.full_hash; the propagation dedup/identity key,
/// distinct from LXMessage.hash). The destination encryption of the tail is NOT performed here — it
/// lives at the Transport/Endpoint boundary (as with opportunistic delivery); this namespace treats
/// the encrypted tail as opaque bytes. Mirrors lxmf 1.1.0 LXMessage.pack() PROPAGATED (LXMessage.py:429-436).
public enum LXMFPropagation {
    /// Propagation identity / dedup key: SHA-256 of a full lxmf_data entry.
    public static func transientId(lxmfData: Data) -> Data {
        Crypto.fullHash(lxmfData)
    }

    /// The recipient's lxmf.delivery destination hash — the leading 16 bytes of an entry (nil if short).
    public static func destinationHash(lxmfData: Data) -> Data? {
        guard lxmfData.count >= LXMessage.destinationLength else { return nil }
        return Data(lxmfData.prefix(LXMessage.destinationLength))
    }

    /// Assemble one entry from a destination hash and the recipient-encrypted tail.
    public static func lxmfData(destinationHash: Data, encryptedData: Data) -> Data {
        destinationHash + encryptedData
    }

    /// Pack the propagation-node container: msgpack([timestamp, [entries…]]).
    public static func container(timestamp: Double, entries: [Data]) -> Data {
        MsgPack.encode(.array([.double(timestamp), .array(entries.map { .bin($0) })]))
    }

    /// Default propagation stamp cost for client→PN offers (RNS PROPAGATION_COST = 16).
    public static let defaultPropagationStampCost = 16

    /// `LXMPeer.ERROR_NO_IDENTITY` (lxmf 1.1.0 LXMPeer.py:24) — the response BODY a propagation node
    /// returns for a request on a link that never IDENTIFY'd (LXMRouter.py:1483). Reference clients
    /// compare the decoded response against this integer (LXMRouter.py:1563 / :1608) to tear the link
    /// down and set `PR_NO_IDENTITY_RCVD`, so it must round-trip as the msgpack integer 0xF0 —
    /// `umsgpack.packb(0xf0)` → `CC F0` (uint8), which `MsgPack.encode(.uint(240))` reproduces.
    public static let errorNoIdentity: UInt64 = 0xF0

    /// Strip the trailing 32-byte PN stamp from a raw `lxmf_data` entry when the entry is long enough
    /// to contain one (i.e. `count > destinationLength + stampSize`), and return the stampless core.
    /// When the entry is at or below the threshold the bytes are returned unchanged.
    ///
    /// This is a pure size-based heuristic (matching the three existing call sites) used to recover the
    /// canonical stampless entry before computing `transient_id` or decrypting the tail. It does **not**
    /// validate the stamp — use `LXStamper.validatePnStamp` when cryptographic validation is required.
    public static func strippedCore(lxmfData: Data) -> Data {
        guard lxmfData.count > LXMessage.destinationLength + LXStamper.stampSize else { return lxmfData }
        return Data(lxmfData.dropLast(LXStamper.stampSize))
    }

    /// Parse a propagation-node container back into its timestamp and entries; nil if malformed.
    public static func parseContainer(_ data: Data) -> (timestamp: Double, entries: [Data])? {
        guard case let .array(top)? = MsgPack.decodeValue(data), top.count == 2,
              case let .double(ts) = top[0],
              case let .array(items) = top[1] else { return nil }
        var entries: [Data] = []
        for item in items {
            guard case let .bin(d) = item else { return nil }
            entries.append(d)
        }
        return (ts, entries)
    }
}
