import Foundation

/// LXMF propagation container + transient id (LXMF-4d-1). Pure wire helpers for the store-and-forward
/// format a propagation node stores and serves: `msgpack([timestamp, [lxmf_data…]])`, where each
/// `lxmf_data = destinationHash(16) ‖ destination-encrypted(sourceHash‖signature‖payload)` and
/// `transient_id = full_hash(lxmf_data)` (RNS Identity.full_hash; the propagation dedup/identity key,
/// distinct from LXMessage.hash). The destination encryption of the tail is NOT performed here — it
/// lives at the Transport/Endpoint boundary (as with opportunistic delivery); this namespace treats
/// the encrypted tail as opaque bytes. Mirrors lxmf 1.1.0 LXMessage.pack() PROPAGATED (LXMessage.py:429-436).
public enum LXMFPropagation {
    /// Link-request stamp cost the propagation destination announces (LXMF 1.3.0
    /// `LXMRouter.PROPAGATION_LINK_COST`, set at LXMRouter.py:634).
    public static let propagationLinkCost = 3.25

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

    /// Highest peering cost we will do proof-of-work for, from `LXMRouter.MAX_PEERING_COST = 26`
    /// (lxmf 1.1.0 LXMRouter.py:51; reference's own default `PEERING_COST` is 18, LXMRouter.py:50).
    ///
    /// Exact reference parity, including the *shape* of the response: `LXMRouter.peer`
    /// (LXMRouter.py:2005-2010) **refuses to peer** above this rather than clamping — "Not peering
    /// with …, since its peering cost of {peering_cost} exceeds local maximum of {max_peering_cost}".
    /// Clamping would be wrong here, not merely different: the cost is the *peer's* demand, so a
    /// key generated at a lower cost is one the peer will reject (`LXMPeer.py:228-233` compares the
    /// key's value against `self.peering_cost`). Declining is a clean refusal; clamping is a silent
    /// failure. Cost is exponential — a peering cost of 64 is ~2^64 expected hash iterations.
    public static let maxPeeringCost = 26

    /// Highest propagation stamp cost we will do proof-of-work for when a propagation node advertises
    /// one in its announce app-data.
    ///
    /// **This is a deliberate divergence from reference — reference has no such cap.**
    /// `LXMRouter.get_outbound_propagation_cost` (LXMRouter.py:421-442) returns the announced
    /// `pn_config[5][0]` verbatim, and `pn_announce_data_is_valid` (LXMF.py:238-239) only checks the
    /// field is int-able, not that it is sane. Reference survives a hostile value by making the search
    /// *cancellable* (`LXStamper.cancel_work`, LXStamper.py:146-175, driven from `cancel_outbound`),
    /// not by bounding it — so an uncancelled reference client burns a core just as we would.
    /// `PROPAGATION_COST_MIN = 13` (LXMRouter.py:52) is a **floor on a node's own configured cost**
    /// (applied at LXMRouter.py:137), not a ceiling on what a peer may demand of us.
    ///
    /// We implement cancellation *and* this cap, because an unkillable core burn triggered by an
    /// unauthenticated announce is not acceptable on a mobile client even for the seconds before a
    /// user notices and cancels.
    ///
    /// **Why 20.** It is the largest cost whose worst-case work does not exceed the worst case
    /// reference already sanctions for a peering key: `MAX_PEERING_COST = 26` over the 25-round
    /// peering workblock is ~2^26 × 6.4 KB of hashing, and the propagation workblock is 1000 rounds
    /// (~256 KB, 40× larger), so the equal-work cost is 26 - log2(40) ≈ 20.7. It also clears the
    /// highest cost a reference node can legitimately demand by its own defaults —
    /// `PROPAGATION_COST + PROPAGATION_COST_FLEX` = 16 + 3 = 19 (LXMRouter.py:53-54).
    ///
    /// Refusal, not clamping, for the same reason as `maxPeeringCost`: a stamp generated below the
    /// node's advertised cost is one that node's own ingest will reject (`PropagationStore.ingest`
    /// enforces `minStampCost`; reference LXMRouter.py:2242 likewise), so clamping would spend the
    /// work and still lose the message, silently.
    public static let maxPropagationStampCost = 20

    /// Per-MESSAGE propagation transfer limit in KILOBYTES, announced as PN app-data field [3]
    /// (`LXMRouter.PROPAGATION_LIMIT = 256`, LXMRouter.py:55).
    ///
    /// This field is a REQUEST the announcing node makes of its peers, and the SENDER honours it —
    /// it is never enforced by the receiver. A peer that reads our announce stores this value on the
    /// `LXMPeer` object representing *us* (Handlers.py:61 → LXMRouter.py:2025/2041), then filters its
    /// own outbound offer against it in `LXMPeer.sync` (LXMPeer.py:370), where `self` is that peer
    /// record for us. So the honest value is "the largest single message we are willing to receive",
    /// and under-enforcing it costs a peer nothing — we simply accept more than we asked for.
    ///
    /// It must NOT be lowered below reference's 256 without cause: a message larger than this is
    /// `remove_unhandled_message` + `add_handled_message`'d (LXMPeer.py:371-372), i.e. dropped
    /// PERMANENTLY and never retried. Advertising 0 made that condition unconditional. 256 KB is a
    /// single Resource segment for us (`LinkSession.maxEfficientSize` = 1_048_575), so it lands on the
    /// already-proven single-segment receive path.
    public static let defaultPropagationTransferLimitKB = 256

    /// Aggregate per-SYNC limit in KILOBYTES, announced as PN app-data field [4]
    /// (`LXMRouter.SYNC_LIMIT = PROPAGATION_LIMIT*40` = 10240, LXMRouter.py:59). Derived from the
    /// per-transfer limit rather than restated, mirroring reference — and reference additionally
    /// clamps sync >= transfer (LXMRouter.py:156-157), an invariant this expression cannot violate.
    ///
    /// Exceeding this is less severe than exceeding the transfer limit: the sender merely skips the
    /// message for THIS sync (LXMPeer.py:375-376 `continue` without marking it handled), so it is
    /// retried later. Advertising 0 therefore stalled syncs rather than losing messages outright.
    /// 10240 KB spans ~10 Resource segments inbound, which `ResourceTransfer` handles, and stays
    /// under `LXMFServiceNode.State.defaultStorageLimitBytes` (32 MiB) so one maximal sync cannot by
    /// itself evict the backlog.
    public static let defaultPropagationSyncLimitKB = defaultPropagationTransferLimitKB * 40

    /// `LXMPeer.ERROR_NO_IDENTITY` (lxmf 1.1.0 LXMPeer.py:24) — the response BODY a propagation node
    /// returns for a request on a link that never IDENTIFY'd (LXMRouter.py:1483). Reference clients
    /// compare the decoded response against this integer (LXMRouter.py:1563 / :1608) to tear the link
    /// down and set `PR_NO_IDENTITY_RCVD`, so it must round-trip as the msgpack integer 0xF0 —
    /// `umsgpack.packb(0xf0)` → `CC F0` (uint8), which `MsgPack.encode(.uint(240))` reproduces.
    public static let errorNoIdentity: UInt64 = 0xF0

    /// `LXMPeer.ERROR_INVALID_STAMP` (lxmf 1.1.0 LXMPeer.py:28) — sent as a raw data packet (not a
    /// response) on the link when an inbound PACKET-framed propagation offer contains entries with
    /// invalid or absent PN stamps (LXMRouter.py:2258). After sending, the reference tears the link down
    /// (LXMRouter.py:2259). Wire encoding: `msgpack.packb([0xf5])` → array of one uint8 `91 CC F5`.
    public static let errorInvalidStamp: UInt64 = 0xF5

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
