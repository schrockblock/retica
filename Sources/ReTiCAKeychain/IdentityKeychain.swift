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
///
/// Anti-rotation rules (do not weaken): an existing identity is never overwritten or replaced;
/// every Keychain error fails closed (no mint); nothing is minted while ANY item exists under
/// the shared or a legacy service in any group; a legacy item is deleted only after the shared
/// item is re-read and byte-equal to it, and only that exact item (by persistent reference) —
/// a legacy item holding a DIFFERENT identity is never deleted; items are device-local (never
/// `kSecAttrSynchronizable`).
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
        /// some other access group (e.g. a mistyped legacy group). Minting would rotate the
        /// identity, so nothing is written or deleted.
        case unexpectedItem(service: String)
    }

    /// Rules, in order (spec 2026-09-26-shared-identity-design §5.1):
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
    ///    legacy service; any item anywhere → `.failed(.unexpectedItem)`. Only a truly empty
    ///    keychain mints, add-only → `.created`; a duplicate → re-read, the stored identity wins
    ///    (`.loaded`).
    /// 4. Any read/add error → `.failed`; never mint on error.
    public static func loadOrCreate(
        shared: Location,
        legacy: [Location] = [],
        ops: KeychainOps = .live
    ) -> Outcome {
        if let unscoped = ([shared] + legacy).first(where: { $0.accessGroup?.isEmpty != false }) {
            return .failed(.invalidLocation(unscoped))
        }
        // Only an exact alias of the shared item is dropped: the leftover cleanup would otherwise
        // delete the shared item itself.
        let legacy = legacy.filter { $0 != shared }

        // Rule 1
        switch ops.read(shared) {
        case let .failed(status):
            return .failed(.readFailed(location: shared, status: status))
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
            case .notFound:
                continue
            case let .found(seed, legacyRef):
                guard Identity(privateKey: seed) != nil else {
                    return .failed(.corrupt(location: location))
                }
                return migrate(seed: seed, legacyRef: legacyRef, to: shared, ops: ops)
            }
        }

        // Rule 3
        if let failure = probeForUnexpectedItems(shared: shared, legacy: legacy, ops: ops) {
            return .failed(failure)
        }
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

    private static func migrate(seed: Data, legacyRef: Data, to shared: Location, ops: KeychainOps) -> Outcome {
        switch ops.add(shared, seed) {
        case let .failed(status):
            return .failed(.addFailed(status: status))

        case .duplicate:
            // Another process created the shared item between our read and our add: it wins.
            switch ops.read(shared) {
            case let .failed(status):
                return .failed(.readFailed(location: shared, status: status))
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
        }
    }

    /// Read-only, group-less look for ANY item under the shared or a legacy service, in any
    /// group the app can access. Never deletes or writes through these unscoped locations.
    private static func probeForUnexpectedItems(shared: Location, legacy: [Location], ops: KeychainOps) -> Failure? {
        var services: [String] = []
        for service in [shared.service] + legacy.map(\.service) where !services.contains(service) {
            services.append(service)
        }
        for service in services {
            let anyGroup = Location(service: service, accessGroup: nil)
            switch ops.read(anyGroup) {
            case .notFound:
                continue
            case .found:
                return .unexpectedItem(service: service)
            case let .failed(status):
                return .readFailed(location: anyGroup, status: status)
            }
        }
        return nil
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
