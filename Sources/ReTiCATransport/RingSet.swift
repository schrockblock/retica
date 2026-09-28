import Foundation

/// A bounded, insertion-ordered membership cache. `insert` returns whether the item was new;
/// once `capacity` is exceeded the oldest item is evicted. Used to suppress duplicate packets,
/// replayed announce blobs and repeated path-request tags.
///
/// # ⚠️ REFERENCE SEMANTICS — this is NOT a value type
///
/// The storage is a `final class`, so `var a = b` does **NOT** give two independent rings: both
/// names refer to one cache, and an insert through either is visible through the other. Copying
/// a `Transport.State` therefore shares its rings.
///
/// That is deliberate, and it is the whole point:
///
/// * TCA copies `State` on **every** action (`var currentState = self.state` → reduce into
///   `&currentState` → write back). With value storage the ring's `Set`/`Array` are
///   non-uniquely referenced at the first mutation, so every new packet hash paid a full
///   copy-on-write of both collections. Measured on Apple silicon (-O, TCA pattern) at a
///   262 144-entry ring: **67–82 ms and ~44 MB per received packet**. Boxing makes the copy a
///   single retain.
/// * Sharing is safe **because a dedup ring is a cache, not modelled state**: TCA never rolls an
///   action back, and this memory is never diffed, replayed, persisted or observed. Nothing can
///   observe the difference between "the copy has its own ring" and "the copy shares one" except
///   by getting *better* duplicate suppression.
///
/// Do not add a stored property here that callers need value semantics for.
///
/// The storage carries no synchronisation, and deliberately so: `RingSet` is not `Sendable` (nor
/// are the `State` types that hold it), so Swift 6 concurrency checking already rejects sending
/// one across isolation domains. Every ring lives inside a reducer's `State` and is touched only
/// on that reducer's actor. If a future change needs to hand a ring to a background effect, add a
/// lock at the same time — do not silence the checker with `@unchecked Sendable`.
///
/// # Cost characteristics
///
/// Per `insert`: two SipHash passes over ≤32 bytes, one `Set` insert, one `Set` remove (only
/// once full), one array store. No allocation, no `removeFirst` memmove, no copy-on-write —
/// O(1) regardless of capacity. See `ringSetInsertIsConstantTimeAtLargeCapacity`.
///
/// Steady-state memory at capacity *C* is `48·C` bytes (`Set` bucket array `2C·16` + the
/// circular buffer `C·16`), reached only after *C* distinct items — both collections grow on
/// demand. At `Transport.seenPacketRingSize` (262 144) that is ~12.1 MB; at
/// `Transport.pathRequestTagRingSize` (32 000) ~1.5 MB; at `Transport.announceBlobRingSize`
/// (64) ~3 KB.
public struct RingSet: Equatable {
    /// A 128-bit digest of an inserted item, held **inline** (16 bytes, no heap object).
    ///
    /// Items are digested rather than stored, for two reasons:
    ///
    /// 1. **Memory.** A 32-byte `Data` exceeds Foundation's inline representation, so each stored
    ///    entry costs a `__DataStorage` object plus its buffer (~112 B measured) and every `Set`
    ///    resize or copy walks it with retain/release. Sixteen POD bytes are memcpy-able: at
    ///    262 144 entries this is ~12 MB instead of ~44 MB.
    /// 2. **Correctness of truncation.** Simply keeping the first 16 bytes of the item would be
    ///    wrong here: `Transport.discoveryPrTags` inserts `destinationHash ‖ tag`, whose first 16
    ///    bytes are *the same for every request to one destination* — prefix truncation would
    ///    collapse the tag ring into per-destination dedup. Hashing removes any dependence on
    ///    where the entropy sits in the item.
    ///
    /// Collision risk: with 2¹⁸ live entries and a 128-bit digest, P(any collision) ≈ n²/2¹²⁹ ≈
    /// 2⁻⁹³. The consequence of one would be a single packet dropped as a false duplicate — not a
    /// security property, and Reticulum already identifies destinations and links by 128-bit
    /// truncated hashes, so this matches the protocol's own collision posture.
    ///
    /// `Hasher`'s seed is randomised per process. That is fine — and desirable, since it denies an
    /// attacker precomputed collisions — because a `RingSet` is in-memory only and is never
    /// persisted or compared across processes.
    struct Key: Hashable {
        let a: UInt64
        let b: UInt64
    }

    static func digest(_ item: Data) -> Key {
        item.withUnsafeBytes { raw -> Key in
            var lo = Hasher(); lo.combine(0xA5 as UInt8); lo.combine(bytes: raw)
            var hi = Hasher(); hi.combine(0x5A as UInt8); hi.combine(bytes: raw)
            return Key(a: UInt64(bitPattern: Int64(lo.finalize())),
                       b: UInt64(bitPattern: Int64(hi.finalize())))
        }
    }

    /// Boxed storage: a membership `Set` for O(1) `contains`, plus a circular buffer that records
    /// only eviction order. Writing at a rotating index is what removes the old
    /// `order.removeFirst()` — an `Array.remove(at: 0)`, i.e. a memmove of the entire tail on
    /// every insert past capacity.
    final class Storage {
        let capacity: Int
        private var members: Set<Key> = []
        /// Insertion order. Grows by `append` until `capacity` is reached, then slots are
        /// overwritten in place — the array is never shifted and never shrinks.
        private var order: [Key] = []
        /// Index of the next slot to write.
        private var next = 0
        /// Slots whose key was `remove`d. Such a slot must not evict when the cursor reaches it:
        /// its key may have been inserted again since, into a NEWER slot, and evicting it here
        /// would drop that newer membership early. Empty unless `remove` is used.
        private var removedSlots: Set<Int> = []

        init(capacity: Int) { self.capacity = max(1, capacity) }

        var count: Int { members.count }
        var contents: Set<Key> { members }

        func contains(_ key: Key) -> Bool { members.contains(key) }

        func insert(_ key: Key) -> Bool {
            guard members.insert(key).inserted else { return false }
            if next < order.count {
                // Evict the oldest, unless its key was already removed.
                if removedSlots.remove(next) == nil { members.remove(order[next]) }
                order[next] = key
            } else {
                order.append(key)
            }
            next += 1
            if next >= capacity { next = 0 }
            return true
        }

        /// O(capacity): finds the key's live slot by a linear scan. For rare removals only.
        func remove(_ key: Key) -> Bool {
            guard members.remove(key) != nil else { return false }
            if let slot = order.indices.first(where: { order[$0] == key && !removedSlots.contains($0) }) {
                removedSlots.insert(slot)
            }
            return true
        }
    }

    private let storage: Storage

    /// No default: every ring must state its size against the reference constant it mirrors.
    /// A defaulted capacity is how `seenPacketHashes` silently ran at 1000 instead of 262144.
    public init(capacity: Int) { storage = Storage(capacity: capacity) }

    /// Equality is by **contents**, behind an identity fast path.
    ///
    /// The fast path is the one that matters: `TestStore` builds its expected state by copying the
    /// state whose ring the reducer just mutated, so both sides name the same `Storage` and the
    /// comparison is O(1) — a 262 144-entry ring costs nothing to diff. The contents fallback only
    /// runs for rings constructed independently, which in practice means small rings in tests.
    ///
    /// Contents rather than identity so that `RingSet(capacity: 2) == RingSet(capacity: 2)`
    /// stays true for two empty rings; identity-only equality is lawful but would make a freshly
    /// constructed `Transport.State` unequal to another freshly constructed one, which is a trap.
    /// Note the consequence for `TestStore`: because a copy shares storage, a ring insert is
    /// **invisible** to state diffing. Do not write `$0.seenPacketHashes.insert(h)` in a
    /// `send` closure expecting it to assert anything — it cannot fail. Assert on behaviour
    /// (was the duplicate suppressed?) instead.
    public static func == (lhs: RingSet, rhs: RingSet) -> Bool {
        if lhs.storage === rhs.storage { return true }
        return lhs.storage.capacity == rhs.storage.capacity
            && lhs.storage.contents == rhs.storage.contents
    }

    /// Kept `mutating` even though it mutates through a reference: call sites read as mutations,
    /// and `let` bindings of a shared cache would be misleading.
    @discardableResult
    public mutating func insert(_ item: Data) -> Bool { storage.insert(RingSet.digest(item)) }

    public func contains(_ item: Data) -> Bool { storage.contains(RingSet.digest(item)) }

    /// Forget `item`. Returns whether it was present. O(capacity) — a linear scan for its slot —
    /// so this is for rare removals (an un-cancel), never a per-packet path.
    @discardableResult
    public mutating func remove(_ item: Data) -> Bool { storage.remove(RingSet.digest(item)) }

    /// Number of items currently remembered (never exceeds `capacity`). Test/diagnostic surface.
    public var count: Int { storage.count }
}
