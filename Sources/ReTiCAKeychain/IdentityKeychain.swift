import Foundation
import ReTiCA

/// One Reticulum identity per device, shared by every app on the team through a Keychain
/// access group — read in place, never exported/imported between apps.
///
/// Adopting app (team HK6WSAR793):
/// 1. Entitlement `keychain-access-groups = [$(AppIdentifierPrefix)co.lithobyte.reticulum.identity]`.
/// 2. At launch, synchronously:
///    `IdentityKeychain.loadOrCreate(shared: Location(service: "reticulum.identity",
///    accessGroup: "HK6WSAR793.co.lithobyte.reticulum.identity"), legacy: [<your old item, if any>])`.
///    Every location MUST name its (non-empty) access group. An unentitled legacy item written
///    without a group physically lives in the app-ID group, e.g.
///    `Location(service: "nbhd.identity", accessGroup: "HK6WSAR793.co.lithobyte.Nbhd")`.
///    If a legacy group is named wrongly, the pre-mint probe still sees the item and the load
///    fails with `.unexpectedItem` instead of minting — fix the location; don't work around it.
/// 3. Treat `.failed` as "identity unavailable right now" (e.g. prewarm before first unlock) —
///    NEVER mint a replacement yourself.
/// 4. An app that must not mint — e.g. because it holds memberships — calls `load`, which
///    returns `.absent` instead of minting, and restores with `importIdentity`. Never write an
///    identity yourself: `importIdentity` is the only supported way to store one.
///
/// Anti-rotation rules (do not weaken): an existing identity is never overwritten or replaced;
/// every Keychain error fails closed (no mint); nothing is minted while ANY item exists under
/// the shared or a legacy service in any group; a legacy item is deleted only after the shared
/// item is re-read and byte-equal to it, and only that exact item (by persistent reference) —
/// a legacy item holding a DIFFERENT identity is never deleted; items are device-local (never
/// `kSecAttrSynchronizable`); a location holding more than one item, or any iCloud-synchronizable
/// item, fails closed the same way.
public struct IdentityKeychain {
    /// A generic-password item address. `accessGroup == nil` puts no `kSecAttrAccessGroup` in
    /// the query: reads and deletes then match the service in EVERY group the app can access —
    /// which is why `loadOrCreate` rejects such locations (`Failure.invalidLocation`).
    /// Items are addressed by class + service (+ access group) only — no `kSecAttrAccount` — and
    /// are never `kSecAttrSynchronizable`; any adopting app must write the shared item the same
    /// way, or its copy won't collide/dedupe with the one other apps already wrote.
    public struct Location: Sendable, Hashable {
        public var service: String
        public var accessGroup: String?
        public init(service: String, accessGroup: String?) {
            self.service = service
            self.accessGroup = accessGroup
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The shared item existed (possibly created by another app, or by a concurrent launch).
        case loaded(Identity)
        /// Nothing existed anywhere; a new identity was minted and stored in the shared item.
        case created(Identity)
        /// A legacy item was copied into the shared item, verified, and (normally) deleted.
        case migrated(Identity)
        case failed(Failure)

        public var identity: Identity? {
            switch self {
            case let .loaded(identity), let .created(identity), let .migrated(identity): identity
            case .failed: nil
            }
        }
    }

    /// What `load` found. It is never "created": `load` NEVER mints. A separate type (not a new
    /// `Outcome` case) so adopters' exhaustive `Outcome` switches keep compiling.
    public enum LoadOutcome: Sendable, Equatable {
        /// The shared item existed (possibly created by another app).
        case loaded(Identity)
        /// A legacy item was copied into the shared item, verified, and (normally) deleted.
        case migrated(Identity)
        /// Nothing at the shared location, at any legacy location, or — by the group-less probe —
        /// under either service in any accessible group. Nothing was written. Callers decide
        /// whether that means "fresh install" (mint via `loadOrCreate`) or "key missing" (restore).
        case absent
        case failed(Failure)

        public var identity: Identity? {
            switch self {
            case let .loaded(identity), let .migrated(identity): identity
            case .absent, .failed: nil
            }
        }
    }

    public enum ImportOutcome: Sendable, Equatable {
        /// The key was added to the shared item (add-only) and re-read byte-equal.
        case imported(Identity)
        /// Not a 64-byte Reticulum private key. Nothing was read or written.
        case invalidKey
        /// An item already exists — at a named location, or under a scanned service in another
        /// group (named by `service`). Nothing was written: an existing identity is never replaced.
        case identityPresent(service: String)
        case failed(Failure)
    }

    public enum Failure: Error, Sendable, Equatable {
        /// A read failed with a non-"not found" status (e.g. -25308 errSecInteractionNotAllowed
        /// during prewarm). Whether an identity exists is unknown, so nothing is minted.
        case readFailed(location: Location, status: Int32)
        /// An item exists but isn't a valid 64-byte identity. It is left untouched.
        case corrupt(location: Location)
        /// Adding the shared item failed (e.g. -34018 errSecMissingEntitlement).
        case addFailed(status: Int32)
        /// The shared item couldn't be read back as expected after an add. `status` is the
        /// OSStatus when the re-read itself failed; nil when the item was absent or differed.
        case verifyFailed(status: Int32?)
        case mintFailed
        /// A location has no (or an empty) access group. Rejected before any Keychain access: a
        /// group-less delete matches the service in EVERY accessible group (unbounded — it could
        /// destroy an item never verified), a group-less read picks one of them arbitrarily, and
        /// a group-less add lands in the app's default group instead of the shared one.
        case invalidLocation(Location)
        /// Nothing was found at the named locations, but an item exists under this service in
        /// some other access group (e.g. a mistyped legacy group), or under a legacy service via
        /// the group-less probe. Minting would rotate the identity, so nothing is written or
        /// deleted. (A hit on the SHARED service is not reported this way: it is re-read at the
        /// named shared location and resolved like rule 1 — see `load`'s rule 3 — so this case
        /// only surfaces for a legacy hit, or a shared hit that vanishes on re-read.) Callers
        /// should still treat it as retryable ("not now"), like `readFailed`. Never mint in response.
        case unexpectedItem(service: String)
        /// More than one item at this location. Nothing is read, minted, migrated, deleted or imported.
        case ambiguousItems(location: Location, count: Int)
        /// An item at this location is iCloud-synchronizable. Fails closed the same way.
        case synchronizableItem(location: Location)
    }

    /// The failure a rejected read means at this location.
    static func failure(for rejection: KeychainOps.ReadRejection, at location: Location) -> Failure {
        switch rejection {
        case let .multipleItems(count): return .ambiguousItems(location: location, count: count)
        case .synchronizableItem: return .synchronizableItem(location: location)
        }
    }

    /// Rules 0–3 without the mint (spec 2026-09-28-identity-recovery-design §3):
    /// 0. Every location (shared and legacy) must name a non-empty access group, else
    ///    `.failed(.invalidLocation)` with no Keychain access. A legacy location equal to the
    ///    shared one is ignored (a same-service legacy item in another group IS legacy).
    /// 1. Shared item present → valid: `.loaded` (and byte-identical legacy leftovers of an
    ///    interrupted migration are deleted); corrupt: `.failed` (never overwritten).
    /// 2. Shared absent, a legacy item present (first found, in order) → add its seed to the
    ///    shared item (add-only) → re-read and verify → only then delete that legacy item (by
    ///    persistent reference) → `.migrated`. A duplicate on add means another process created
    ///    the shared item first: it wins (`.loaded`) and the legacy item is kept unless it holds
    ///    the same seed.
    /// 3. Nothing at any named location → a read-only, group-less probe of the shared and every
    ///    legacy service. A hit on the shared service is re-read at the named shared location
    ///    (the other app may have written it between rule 1 and this probe — the first-launch
    ///    race) and resolved exactly like rule 1; a hit on a legacy service, or a shared-service
    ///    hit that vanishes on re-read, → `.failed(.unexpectedItem)`; nothing anywhere →
    ///    `.absent`. NOTHING is minted.
    /// Any read/add error → `.failed`.
    public static func load(
        shared: Location,
        legacy: [Location] = [],
        ops: KeychainOps = .live
    ) -> LoadOutcome {
        if let unscoped = firstUnscoped(shared: shared, legacy: legacy) {
            return .failed(.invalidLocation(unscoped))
        }
        // Only an exact alias of the shared item is dropped: the leftover cleanup would otherwise
        // delete the shared item itself.
        let legacy = legacy.filter { $0 != shared }

        // Rule 1
        switch ops.read(shared) {
        case let .failed(status):
            return .failed(.readFailed(location: shared, status: status))
        case let .rejected(r):
            return .failed(failure(for: r, at: shared))
        case let .found(data, _):
            guard let identity = Identity(privateKey: data) else {
                return .failed(.corrupt(location: shared))
            }
            removeLegacyCopies(of: data, legacy: legacy, ops: ops)
            return .loaded(identity)
        case .notFound:
            break
        }

        // Rule 2
        for location in legacy {
            switch ops.read(location) {
            case let .failed(status):
                return .failed(.readFailed(location: location, status: status))
            case let .rejected(r):
                return .failed(failure(for: r, at: location))
            case .notFound:
                continue
            case let .found(seed, legacyRef):
                guard Identity(privateKey: seed) != nil else {
                    return .failed(.corrupt(location: location))
                }
                return migrate(seed: seed, legacyRef: legacyRef, to: shared, ops: ops)
            }
        }

        // Rule 3 (read-only half). A hit on the shared service itself is re-read: the other app may
        // have written the shared item between rule 1 and the probe (the first-launch race).
        switch probe(shared: shared, legacy: legacy, ops: ops) {
        case .clear:
            return .absent
        case let .failed(failure):
            return .failed(failure)
        case let .hit(service):
            guard service == shared.service else { return .failed(.unexpectedItem(service: service)) }
            switch ops.read(shared) {
            case let .found(data, _):
                guard let identity = Identity(privateKey: data) else { return .failed(.corrupt(location: shared)) }
                removeLegacyCopies(of: data, legacy: legacy, ops: ops)
                return .loaded(identity)
            case .notFound:
                return .failed(.unexpectedItem(service: service))
            case let .failed(status):
                return .failed(.readFailed(location: shared, status: status))
            case let .rejected(rejection):
                return .failed(failure(for: rejection, at: shared))
            }
        }
    }

    /// `load`, then — only when it is `.absent` — mint add-only into the shared item → `.created`;
    /// a duplicate on add → re-read, the stored identity wins (`.loaded`). One rule path: every
    /// guarantee of `load` holds here, and nothing is minted on any error or while any item exists.
    public static func loadOrCreate(
        shared: Location,
        legacy: [Location] = [],
        ops: KeychainOps = .live
    ) -> Outcome {
        switch load(shared: shared, legacy: legacy, ops: ops) {
        case let .loaded(identity): return .loaded(identity)
        case let .migrated(identity): return .migrated(identity)
        case let .failed(failure): return .failed(failure)
        case .absent: return mint(into: shared, ops: ops)
        }
    }

    private static func mint(into shared: Location, ops: KeychainOps) -> Outcome {
        let minted = Identity()
        guard let seed = minted.privateKey else { return .failed(.mintFailed) }
        switch ops.add(shared, seed) {
        case .added:
            return .created(minted)
        case .duplicate:
            return rereadWinner(shared, ops: ops)
        case let .failed(status):
            return .failed(.addFailed(status: status))
        }
    }

    /// The first location with no (or an empty) access group — rejected before any Keychain access.
    private static func firstUnscoped(shared: Location, legacy: [Location]) -> Location? {
        ([shared] + legacy).first(where: { $0.accessGroup?.isEmpty != false })
    }

    /// Stores a user-supplied identity (e.g. restored from an Identity Export backup) into the
    /// shared item — only when NO identity or item exists anywhere. In order (spec 2026-09-28 §3):
    /// 1. The key is exactly 64 bytes and `Identity(privateKey:)` accepts it, else `.invalidKey`
    ///    (before any Keychain access).
    /// 2. Every location names a non-empty access group, else `.failed(.invalidLocation)`.
    /// 3. Full scan: the shared location, every legacy location, then the read-only group-less
    ///    probe of every scanned service. Any item → `.identityPresent`; any read error →
    ///    `.failed` (unknown is never "empty").
    /// 4. Add-only into the shared location. A duplicate (another process won the race) → re-read:
    ///    the same bytes → `.imported`; different → `.identityPresent` (the stored identity wins).
    /// 5. Re-read and verify byte-equality → `.imported`.
    /// It NEVER deletes and NEVER overwrites.
    public static func importIdentity(
        privateKey: Data,
        shared: Location,
        legacy: [Location] = [],
        ops: KeychainOps = .live
    ) -> ImportOutcome {
        // 1
        guard privateKey.count == Identity.keySize, let candidate = Identity(privateKey: privateKey) else {
            return .invalidKey
        }
        // 2
        if let unscoped = firstUnscoped(shared: shared, legacy: legacy) {
            return .failed(.invalidLocation(unscoped))
        }
        let legacy = legacy.filter { $0 != shared }

        // 3 — named locations
        for location in [shared] + legacy {
            switch ops.read(location) {
            case .notFound:
                continue
            case .found:
                return .identityPresent(service: location.service)
            case let .failed(status):
                return .failed(.readFailed(location: location, status: status))
            case let .rejected(r):
                return .failed(failure(for: r, at: location))
            }
        }
        // 3 — any group
        switch probe(shared: shared, legacy: legacy, ops: ops) {
        case .clear: break
        case let .hit(service): return .identityPresent(service: service)
        case let .failed(failure): return .failed(failure)
        }

        // 4
        switch ops.add(shared, privateKey) {
        case let .failed(status):
            return .failed(.addFailed(status: status))
        case .duplicate:
            switch ops.read(shared) {
            case let .failed(status):
                return .failed(.readFailed(location: shared, status: status))
            case let .rejected(r):
                return .failed(failure(for: r, at: shared))
            case .notFound:
                return .failed(.verifyFailed(status: nil))
            case let .found(data, _):
                guard data == privateKey else { return .identityPresent(service: shared.service) }
                return .imported(candidate)
            }
        case .added:
            // 5
            switch ops.read(shared) {
            case let .failed(status):
                return .failed(.verifyFailed(status: status))
            case let .rejected(r):
                return .failed(failure(for: r, at: shared))
            case .notFound:
                return .failed(.verifyFailed(status: nil))
            case let .found(data, _):
                guard data == privateKey else { return .failed(.verifyFailed(status: nil)) }
                return .imported(candidate)
            }
        }
    }

    private static func migrate(seed: Data, legacyRef: Data, to shared: Location, ops: KeychainOps) -> LoadOutcome {
        switch ops.add(shared, seed) {
        case let .failed(status):
            return .failed(.addFailed(status: status))

        case .duplicate:
            // Another process created the shared item between our read and our add: it wins.
            switch ops.read(shared) {
            case let .failed(status):
                return .failed(.readFailed(location: shared, status: status))
            case let .rejected(r):
                return .failed(failure(for: r, at: shared))
            case .notFound:
                return .failed(.verifyFailed(status: nil))
            case let .found(data, _):
                guard let winner = Identity(privateKey: data) else {
                    return .failed(.corrupt(location: shared))
                }
                guard data == seed else {
                    // A DIFFERENT identity won: keep the legacy item intact (recoverable).
                    return .loaded(winner)
                }
                _ = ops.deleteItem(legacyRef)
                return .migrated(winner)
            }

        case .added:
            // On any verify failure the legacy item is kept; the next load resolves (rule 1
            // loads a good copy and removes the identical leftover).
            let stored: Data
            switch ops.read(shared) {
            case let .failed(status):
                return .failed(.verifyFailed(status: status))
            case let .rejected(r):
                return .failed(failure(for: r, at: shared))
            case .notFound:
                return .failed(.verifyFailed(status: nil))
            case let .found(data, _):
                stored = data
            }
            guard stored == seed, let identity = Identity(privateKey: stored) else {
                return .failed(.verifyFailed(status: nil))
            }
            // Deletes exactly the legacy item whose bytes were copied and verified. A failed
            // delete is harmless: the identity is safe in the shared item and the next load
            // removes the identical leftover.
            _ = ops.deleteItem(legacyRef)
            return .migrated(identity)
        }
    }

    private static func rereadWinner(_ shared: Location, ops: KeychainOps) -> Outcome {
        switch ops.read(shared) {
        case let .found(data, _):
            guard let winner = Identity(privateKey: data) else {
                return .failed(.corrupt(location: shared))
            }
            return .loaded(winner)
        case .notFound:
            return .failed(.verifyFailed(status: nil))
        case let .failed(status):
            return .failed(.readFailed(location: shared, status: status))
        case let .rejected(r):
            return .failed(failure(for: r, at: shared))
        }
    }

    enum ProbeResult: Equatable {
        case clear
        case hit(service: String)
        case failed(Failure)
    }

    /// Read-only, group-less look for ANY item under the shared or a legacy service, in any
    /// group the app can access. Never deletes or writes through these unscoped locations.
    private static func probe(shared: Location, legacy: [Location], ops: KeychainOps) -> ProbeResult {
        var services: [String] = []
        for service in [shared.service] + legacy.map(\.service) where !services.contains(service) {
            services.append(service)
        }
        for service in services {
            let anyGroup = Location(service: service, accessGroup: nil)
            switch ops.read(anyGroup) {
            case .notFound:
                continue
            case .found, .rejected(.multipleItems):
                return .hit(service: service)
            case .rejected(.synchronizableItem):
                return .failed(.synchronizableItem(location: anyGroup))
            case let .failed(status):
                return .failed(.readFailed(location: anyGroup, status: status))
            }
        }
        return .clear
    }

    public struct LegacyConflict: Sendable, Equatable {
        public var location: Location
        /// The 16-byte identity hash of the legacy item.
        public var identityHash: Data
        public init(location: Location, identityHash: Data) {
            self.location = location
            self.identityHash = identityHash
        }
    }

    public enum ConflictOutcome: Sendable, Equatable {
        case none
        /// `sharedHash` is the shared item's identity hash, or nil when the shared item is absent
        /// and the reference was the first legacy identity (the one migration would copy).
        case conflicts(sharedHash: Data?, legacy: [LegacyConflict])
        case failed(Failure)
    }

    /// Read-only (spec 2026-09-29 §4.4): every legacy item holding a valid identity that differs
    /// from the reference — the shared item's identity, or, when the shared item is absent, the
    /// first legacy identity found (it would win the migration). Corrupt, unreadable or rejected
    /// items fail. The group-less probe is NOT run (a conflict query names its locations; strays
    /// are `load`'s job). Nothing is ever written or deleted.
    public static func legacyConflicts(
        shared: Location,
        legacy: [Location] = [],
        ops: KeychainOps = .live
    ) -> ConflictOutcome {
        if let unscoped = firstUnscoped(shared: shared, legacy: legacy) {
            return .failed(.invalidLocation(unscoped))
        }
        let legacy = legacy.filter { $0 != shared }

        var reference: Data?
        var sharedHash: Data?
        switch ops.read(shared) {
        case let .failed(status):
            return .failed(.readFailed(location: shared, status: status))
        case let .rejected(rejection):
            return .failed(failure(for: rejection, at: shared))
        case let .found(data, _):
            guard let identity = Identity(privateKey: data) else { return .failed(.corrupt(location: shared)) }
            reference = identity.hash
            sharedHash = identity.hash
        case .notFound:
            break
        }

        var conflicts: [LegacyConflict] = []
        for location in legacy {
            switch ops.read(location) {
            case .notFound:
                continue
            case let .failed(status):
                return .failed(.readFailed(location: location, status: status))
            case let .rejected(rejection):
                return .failed(failure(for: rejection, at: location))
            case let .found(data, _):
                guard let identity = Identity(privateKey: data) else { return .failed(.corrupt(location: location)) }
                guard let winner = reference else {
                    reference = identity.hash
                    continue
                }
                if identity.hash != winner {
                    conflicts.append(LegacyConflict(location: location, identityHash: identity.hash))
                }
            }
        }
        return conflicts.isEmpty ? .none : .conflicts(sharedHash: sharedHash, legacy: conflicts)
    }

    /// Finishes an interrupted migration: deletes the legacy item holding exactly the shared
    /// seed, by the persistent reference of the item just read. Errors are ignored — the load
    /// already succeeded, and a different identity is never touched.
    private static func removeLegacyCopies(of data: Data, legacy: [Location], ops: KeychainOps) {
        for location in legacy {
            if case let .found(legacyData, ref) = ops.read(location), legacyData == data {
                _ = ops.deleteItem(ref)
            }
        }
    }
}
