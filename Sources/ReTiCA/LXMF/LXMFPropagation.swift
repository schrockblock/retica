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
