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
/// 3. Treat `.failed` as "identity unavailable right now" (e.g. prewarm before first unlock) —
///    NEVER mint a replacement yourself.
///
/// Anti-rotation rules (do not weaken): an existing identity is never overwritten or replaced;
/// every Keychain error fails closed (no mint); a legacy item is deleted only after the shared
/// item is re-read and byte-equal to it, and a legacy item holding a DIFFERENT identity is never
/// deleted; items are device-local (never `kSecAttrSynchronizable`).
public struct IdentityKeychain {
    /// A generic-password item address. `accessGroup == nil` puts no `kSecAttrAccessGroup` in
    /// the query: reads and deletes then match the service in EVERY group the app can access.
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
        /// An add reported success but the shared item couldn't be read back as expected.
        case verifyFailed
        case mintFailed
    }

    /// Rules, in order (spec 2026-09-26-shared-identity-design §5.1):
    /// 1. Shared item present → valid: `.loaded` (and byte-identical legacy leftovers of an
    ///    interrupted migration are deleted); corrupt: `.failed` (never overwritten).
    /// 2. Shared absent, a legacy item present (first found, in order) → add its seed to the
    ///    shared item (add-only) → re-read and verify → only then delete the legacy item →
    ///    `.migrated`. A duplicate on add means another process created the shared item first:
    ///    it wins (`.loaded`) and the legacy item is kept unless it holds the same seed.
    /// 3. Nothing anywhere → mint, add-only → `.created`; a duplicate → re-read, the stored
    ///    identity wins (`.loaded`).
    /// 4. Any read/add error → `.failed`; never mint on error.
    public static func loadOrCreate(
        shared: Location,
        legacy: [Location] = [],
        ops: KeychainOps = .live
    ) -> Outcome {
        // A legacy location that would match the shared item itself must never be read as
        // "legacy" — the leftover cleanup would delete the shared item.
        let legacy = legacy.filter { location in
            !(location.service == shared.service
              && (location.accessGroup == nil || location.accessGroup == shared.accessGroup))
        }

        // Rule 1
        switch ops.read(shared) {
        case let .failed(status):
            return .failed(.readFailed(location: shared, status: status))
        case let .found(data):
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
            case let .found(seed):
                guard Identity(privateKey: seed) != nil else {
                    return .failed(.corrupt(location: location))
                }
                return migrate(seed: seed, from: location, to: shared, ops: ops)
            }
        }

        // Rule 3
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

    private static func migrate(seed: Data, from legacyLocation: Location, to shared: Location, ops: KeychainOps) -> Outcome {
        switch ops.add(shared, seed) {
        case let .failed(status):
            return .failed(.addFailed(status: status))

        case .duplicate:
            // Another process created the shared item between our read and our add: it wins.
            switch ops.read(shared) {
            case let .failed(status):
                return .failed(.readFailed(location: shared, status: status))
            case .notFound:
                return .failed(.verifyFailed)
            case let .found(data):
                guard let winner = Identity(privateKey: data) else {
                    return .failed(.corrupt(location: shared))
                }
                guard data == seed else {
                    // A DIFFERENT identity won: keep the legacy item intact (recoverable).
                    return .loaded(winner)
                }
                _ = ops.delete(legacyLocation)
                return .migrated(winner)
            }

        case .added:
            guard case let .found(stored) = ops.read(shared), stored == seed,
                  let identity = Identity(privateKey: stored) else {
                // Legacy item kept; the next load resolves (rule 1 loads a good copy and
                // removes the identical leftover).
                return .failed(.verifyFailed)
            }
            // A failed delete is harmless: the identity is safe in the shared item and the next
            // load removes the identical leftover.
            _ = ops.delete(legacyLocation)
            return .migrated(identity)
        }
    }

    private static func rereadWinner(_ shared: Location, ops: KeychainOps) -> Outcome {
        switch ops.read(shared) {
        case let .found(data):
            guard let winner = Identity(privateKey: data) else {
                return .failed(.corrupt(location: shared))
            }
            return .loaded(winner)
        case .notFound:
            return .failed(.verifyFailed)
        case let .failed(status):
            return .failed(.readFailed(location: shared, status: status))
        }
    }

    /// Finishes an interrupted migration: deletes legacy items holding exactly the shared seed.
    /// Errors are ignored — the load already succeeded, and a different identity is never touched.
    private static func removeLegacyCopies(of data: Data, legacy: [Location], ops: KeychainOps) {
        for location in legacy {
            if case let .found(legacyData) = ops.read(location), legacyData == data {
                _ = ops.delete(location)
            }
        }
    }
}
