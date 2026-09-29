# Keychain Hardening Implementation Plan (ReTiCAKeychain, Part A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Keychain read in `ReTiCAKeychain` sees all matching items and fails closed on duplicates or iCloud-synchronizable items; the pre-mint probe resolves the first-launch race by re-reading the shared location; a read-only `legacyConflicts` query; and a base32 `IdentityBackup` codec — all before ReTiCaMsgr adopts the shared identity.

**Architecture:** `KeychainOps.read` gains a `rejected(ReadRejection)` result computed from a match-limit-all, synchronizable-any query; `IdentityKeychain` maps it to two new `Failure` cases at every read site and treats them like any other failure (nothing minted, migrated, deleted or imported). The probe returns a small enum so a hit on the shared service can re-read the shared location. `legacyConflicts` and `IdentityBackup` are additive and pure over the same `KeychainOps`.

**Tech Stack:** Swift 6 language mode, Swift Testing, `Security` framework, the existing `InMemoryKeychain` test double.

**Spec:** `/Users/ell/development/ios/apps/ReTiCaMsgr/docs/superpowers/specs/2026-09-29-shared-identity-adoption-design.md` §4 (Part A). A pointer lives at `docs/superpowers/specs/2026-09-29-keychain-hardening-design.md` in this repo.

## Global Constraints

- Work only in the worktree `/Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening` (branch `feat/keychain-hardening`). Never commit in `/Users/ell/development/ios/pods/ReTiCA` (another session works there).
- Package: `Package.swift` unchanged (targets `ReTiCAKeychain`, `ReTiCAKeychainTests`, `swiftLanguageModes: [.v6]`). No new dependencies.
- Anti-rotation rules (spec §4, and the header comment of `IdentityKeychain.swift`) are never weakened: an existing identity is never overwritten or replaced; every Keychain error fails closed; nothing is minted while ANY item exists under the shared or a legacy service; a legacy item is deleted only after the shared item is re-read byte-equal, by persistent reference.
- Writes never set `kSecAttrSynchronizable`; `addAttributes` keeps `kSecAttrAccessibleAfterFirstUnlock`.
- New `Failure` cases are exactly `ambiguousItems(location: Location, count: Int)` and `synchronizableItem(location: Location)`. `ReadRejection` cases are exactly `multipleItems(count: Int)` and `synchronizableItem`.
- Test command: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening --filter ReTiCAKeychainTests`. Run one `swift test` at a time.
- Every new test follows the mutation protocol: green → mutate production → red → revert by hand → green. Masked mutations go in separate sub-batches.
- No key material in logs or test output beyond hashes.

## Review Focus

1. An item whose `kSecAttrSynchronizable` attribute is absent (older items never carried it) must read as non-synchronizable — pinned by `mapRead` with attributes lacking the key (Task 1).
2. `kSecAttrSynchronizable` bridges as `NSNumber`/`CFBoolean`, not always `Bool` — pinned by `isSynchronizable` accepting `NSNumber(value: 1)` (Task 1).
3. A rejected read inside `removeLegacyCopies` must delete nothing — pinned by a duplicate legacy pair alongside a good shared item: `.loaded`, both legacy items kept (Task 1).
4. The race re-read runs only for a hit on the shared service; a legacy-service hit stays `unexpectedItem` without any shared re-read — pinned by counting reads through the `onBeforeRead` hook (Task 2).
5. `decodeBase32` rejects text with a trailing newline (callers trim) — pinned in Task 4.

---

### Task 1: Reads see every item

**Files:**
- Modify: `Sources/ReTiCAKeychain/KeychainOps.swift`
- Modify: `Sources/ReTiCAKeychain/InMemoryKeychain.swift`
- Modify: `Sources/ReTiCAKeychain/IdentityKeychain.swift`
- Modify: `Tests/ReTiCAKeychainTests/KeychainOpsTests.swift`
- Create: `Tests/ReTiCAKeychainTests/IdentityKeychainHardeningTests.swift`

**Interfaces:**
- Consumes: today's `KeychainOps`, `InMemoryKeychain`, `IdentityKeychain`.
- Produces: `KeychainOps.ReadRejection`, `KeychainOps.ReadResult.rejected`, `KeychainOps.mapRead(status:items:)`, `KeychainOps.isSynchronizable(_:)`, `IdentityKeychain.Failure.ambiguousItems` / `.synchronizableItem`, `IdentityKeychain.failure(for:at:)` (internal), `InMemoryKeychain.set(_:at:account:synchronizable:)`.

- [ ] **Step 1: Write the failing tests**

Replace the two live tests in `Tests/ReTiCAKeychainTests/KeychainOpsTests.swift` and rewrite `inMemoryDeleteItemRemovesOnlyTheItemRead`:

```swift
    @Test func liveQueriesAreScopedAndSeeEveryItem() {
        let read = KeychainOps.readQuery(grouped)
        #expect(read[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(read[kSecAttrService as String] as? String == "svc")
        #expect(read[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecReturnAttributes as String] as? Bool == true)
        #expect(read[kSecReturnPersistentRef as String] as? Bool == true)
        // Every item, synced or not, so duplicates and iCloud copies are visible (never silently picked).
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(read[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String)

        let add = KeychainOps.addAttributes(grouped, data: Data([1, 2, 3]))
        #expect(add[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(add[kSecValueData as String] as? Data == Data([1, 2, 3]))
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)

        let delete = KeychainOps.deleteQuery(grouped)
        #expect(delete[kSecAttrAccessGroup as String] as? String == "TEAMID.group")
        #expect(delete[kSecReturnData as String] == nil)

        let deleteItem = KeychainOps.deleteItemQuery(Data([7]))
        #expect(deleteItem[kSecValuePersistentRef as String] as? Data == Data([7]))
        #expect(deleteItem[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(deleteItem[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(deleteItem[kSecAttrService as String] == nil)
        #expect(deleteItem[kSecAttrAccessGroup as String] == nil)

        // Writes and deletes never touch the synchronizable attribute (items stay device-local).
        for query in [add, delete, deleteItem] {
            #expect(query[kSecAttrSynchronizable as String] == nil)
        }
        #expect(KeychainOps.readQuery(ungrouped)[kSecAttrAccessGroup as String] == nil)
    }

    private func item(_ data: Data?, ref: Data?, synchronizable: Any? = nil) -> [String: Any] {
        var attributes: [String: Any] = [:]
        if let data { attributes[kSecValueData as String] = data }
        if let ref { attributes[kSecValuePersistentRef as String] = ref }
        if let synchronizable { attributes[kSecAttrSynchronizable as String] = synchronizable }
        return attributes
    }

    @Test func liveStatusMapping() {
        let one = item(Data([9]), ref: Data([5]))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [one]) == .found(Data([9]), persistentRef: Data([5])))
        // An item that never carried the attribute is device-local.
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(Data([9]), ref: Data([5]), synchronizable: false)])
                == .found(Data([9]), persistentRef: Data([5])))
        // success without data or ref is NOT first-run: treating it as absent would mint (rotation).
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(nil, ref: Data([5]))]) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(Data([9]), ref: nil)]) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: nil) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: []) == .failed(errSecSuccess))
        #expect(KeychainOps.mapRead(status: errSecItemNotFound, items: nil) == .notFound)
        #expect(KeychainOps.mapRead(status: errSecInteractionNotAllowed, items: nil) == .failed(errSecInteractionNotAllowed))
        // Two items: never pick one.
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [one, item(Data([8]), ref: Data([6]))])
                == .rejected(.multipleItems(count: 2)))
        // A synced item is refused even when it is the only one, and before counting.
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [item(Data([9]), ref: Data([5]), synchronizable: true)])
                == .rejected(.synchronizableItem))
        #expect(KeychainOps.mapRead(status: errSecSuccess, items: [one, item(Data([8]), ref: Data([6]), synchronizable: NSNumber(value: 1))])
                == .rejected(.synchronizableItem))
        #expect(KeychainOps.isSynchronizable([kSecAttrSynchronizable as String: NSNumber(value: 1)]))
        #expect(KeychainOps.isSynchronizable([kSecAttrSynchronizable as String: kCFBooleanTrue as Any]))
        #expect(!KeychainOps.isSynchronizable([kSecAttrSynchronizable as String: NSNumber(value: 0)]))
        #expect(!KeychainOps.isSynchronizable([:]))

        #expect(KeychainOps.mapAdd(status: errSecSuccess) == .added)
        #expect(KeychainOps.mapAdd(status: errSecDuplicateItem) == .duplicate)
        #expect(KeychainOps.mapAdd(status: errSecMissingEntitlement) == .failed(errSecMissingEntitlement))
        #expect(KeychainOps.mapDelete(status: errSecSuccess) == .deleted)
        #expect(KeychainOps.mapDelete(status: errSecItemNotFound) == .notFound)
        #expect(KeychainOps.mapDelete(status: errSecInteractionNotAllowed) == .failed(errSecInteractionNotAllowed))
    }

    @Test func inMemoryRejectsMultipleAndSynchronizableItems() {
        let keychain = InMemoryKeychain([grouped: Data([1])])
        keychain.set(Data([2]), at: grouped, account: "other")
        #expect(keychain.ops.read(grouped) == .rejected(.multipleItems(count: 2)))
        #expect(keychain.ops.read(ungrouped) == .rejected(.multipleItems(count: 2)))
        keychain.set(nil, at: grouped, account: "other")
        #expect(keychain.ops.read(grouped).data == Data([1]))
        // A synced copy in another group is seen by the group-less read and refused.
        let elsewhere = IdentityKeychain.Location(service: "svc", accessGroup: "OTHER.group")
        keychain.set(Data([3]), at: elsewhere, synchronizable: true)
        #expect(keychain.ops.read(ungrouped) == .rejected(.synchronizableItem))
        #expect(keychain.ops.read(grouped).data == Data([1]))
        #expect(keychain.ops.read(elsewhere) == .rejected(.synchronizableItem))
        #expect(keychain.item(at: elsewhere) == Data([3]))
        // `add` never stores a synchronizable item.
        let fresh = IdentityKeychain.Location(service: "fresh", accessGroup: "TEAMID.group")
        #expect(keychain.ops.add(fresh, Data([4])) == .added)
        #expect(keychain.ops.read(fresh).data == Data([4]))
    }

    /// Items differing only by account share a location query; `deleteItem` removes just the one read.
    @Test func inMemoryDeleteItemRemovesOnlyTheItemRead() {
        let keychain = InMemoryKeychain()
        keychain.set(Data([1]), at: grouped)
        guard case let .found(data, ref) = keychain.ops.read(grouped) else {
            Issue.record("expected .found")
            return
        }
        #expect(data == Data([1]))
        keychain.set(Data([2]), at: grouped, account: "other")
        #expect(keychain.ops.read(grouped) == .rejected(.multipleItems(count: 2)))
        #expect(keychain.ops.deleteItem(ref) == .deleted)
        #expect(keychain.item(at: grouped) == nil)
        #expect(keychain.item(at: grouped, account: "other") == Data([2]))
        #expect(keychain.ops.read(grouped).data == Data([2]))
        #expect(keychain.ops.deleteItem(ref) == .notFound)
        // The query delete, by contrast, removes every account.
        keychain.set(Data([1]), at: grouped)
        #expect(keychain.ops.delete(grouped) == .deleted)
        #expect(keychain.item(at: grouped, account: "other") == nil)
    }
```

Create `Tests/ReTiCAKeychainTests/IdentityKeychainHardeningTests.swift`:

```swift
import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: "TEAMID.co.example.app")
private let wrongGroup = "TEAMID.co.example.wrong"

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Spec 2026-09-29 §4.1–4.2: a read that finds more than one item, or any iCloud-synchronizable
/// item, fails closed everywhere. Nothing is minted, migrated, deleted or imported past it.
@Suite("IdentityKeychain hardening: duplicates and synchronizable items")
struct IdentityKeychainHardeningTests {

    @Test func loadFailsClosedOnTwoItemsAtTheSharedLocation() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([shared: a])
        keychain.set(b, at: shared, account: "second")
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == a)
        #expect(keychain.item(at: shared, account: "second") == b)
    }

    @Test func loadFailsClosedOnASynchronizableSharedItem() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.set(data, at: shared, synchronizable: true)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: shared)))
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: shared)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == data)
    }

    @Test func loadFailsClosedOnASynchronizableLegacyItemAndMigratesNothing() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.set(data, at: legacy, synchronizable: true)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: legacy)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
        #expect(keychain.item(at: legacy) == data)
    }

    @Test func loadFailsClosedOnTwoLegacyItems() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([legacy: a])
        keychain.set(b, at: legacy, account: "second")
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: legacy, count: 2)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
    }

    /// The group-less probe now sees synced strays too.
    @Test func loadProbeSeesASynchronizableStray() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: legacy.service, accessGroup: wrongGroup)
        let keychain = InMemoryKeychain()
        keychain.set(data, at: stray, synchronizable: true)
        let anyGroup = IdentityKeychain.Location(service: legacy.service, accessGroup: nil)
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: anyGroup)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: stray) == data)
    }

    /// Several strays under one service are still "an unexpected item exists".
    @Test func loadProbeWithSeveralStraysIsAnUnexpectedItem() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([
            IdentityKeychain.Location(service: legacy.service, accessGroup: wrongGroup): a,
            IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.other"): b,
        ])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: legacy.service)))
        #expect(keychain.addCount == 0)
    }

    /// A good shared item next to a duplicated legacy pair: loads, deletes nothing (the leftover
    /// cleanup only ever removes a single byte-equal item it could read).
    @Test func loadKeepsADuplicatedLegacyPairNextToAGoodSharedItem() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data, legacy: data])
        keychain.set(data, at: legacy, account: "second")
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == data)
        #expect(keychain.item(at: legacy, account: "second") == data)
    }

    /// Another process adds the shared item during migration, and the re-read finds two: fail,
    /// keep the legacy item.
    @Test func migrationDuplicateRereadRejectedFailsAndKeepsLegacy() {
        let (_, legacySeed) = makeSeed()
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([legacy: legacySeed])
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(a, at: shared)
            keychain.set(b, at: shared, account: "second")
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: legacy) == legacySeed)
    }

    @Test func importRefusesOnTwoItemsAtTheSharedLocation() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let (_, candidate) = makeSeed()
        let keychain = InMemoryKeychain([shared: a])
        keychain.set(b, at: shared, account: "second")
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.addCount == 0)
    }

    @Test func importRefusesOnASynchronizableStray() {
        let (_, data) = makeSeed()
        let (_, candidate) = makeSeed()
        let stray = IdentityKeychain.Location(service: shared.service, accessGroup: wrongGroup)
        let keychain = InMemoryKeychain()
        keychain.set(data, at: stray, synchronizable: true)
        let anyGroup = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.synchronizableItem(location: anyGroup)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == nil)
    }

    /// The verify re-read after a successful import add finds a second item: fail, nothing deleted.
    @Test func importVerifyRereadRejectedFails() {
        let (_, candidate) = makeSeed()
        let (_, other) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeAdd { location in
            guard location == shared else { return }
            keychain.set(other, at: shared, account: "second")
        }
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.item(at: shared) == candidate)
        #expect(keychain.item(at: shared, account: "second") == other)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening --filter ReTiCAKeychainTests`
Expected: compile errors (`rejected`, `mapRead(status:items:)`, `isSynchronizable`, `set(_:at:account:synchronizable:)`, `ambiguousItems`, `synchronizableItem` do not exist).

- [ ] **Step 3: Implement `KeychainOps`**

In `Sources/ReTiCAKeychain/KeychainOps.swift`, replace `ReadResult` and the live read, `readQuery` and `mapRead`:

```swift
    public enum ReadRejection: Sendable, Equatable {
        /// More than one item matched the query (two accounts at one location, or the group-less
        /// probe found the service in several groups). One is never picked.
        case multipleItems(count: Int)
        /// At least one matching item is `kSecAttrSynchronizable`: an iCloud-synced identity would
        /// split direct LXMF delivery across devices, so it is refused even when it is the only one.
        case synchronizableItem
    }

    public enum ReadResult: Sendable, Equatable {
        /// Exactly one device-local item: its bytes and its persistent reference, which addresses
        /// exactly that item (whatever its account) for `deleteItem`.
        case found(Data, persistentRef: Data)
        case notFound
        case failed(Int32)
        /// Items exist but the read refuses to pick one (see `ReadRejection`). Callers fail closed.
        case rejected(ReadRejection)

        /// The item's bytes when found.
        public var data: Data? {
            if case let .found(data, _) = self { return data }
            return nil
        }
    }
```

Live read:

```swift
        read: { location in
            var result: AnyObject?
            let status = SecItemCopyMatching(readQuery(location) as CFDictionary, &result)
            return mapRead(status: status, items: result as? [[String: Any]])
        },
```

`readQuery`:

```swift
    /// Every item the location matches, synced or not, with attributes, data and persistent ref
    /// (the result is then an array of attribute dictionaries). Match-limit-all and
    /// synchronizable-any make duplicates and iCloud copies visible instead of silently picking one.
    static func readQuery(_ location: IdentityKeychain.Location) -> [String: Any] {
        var query = baseQuery(location)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }
```

`mapRead` and `isSynchronizable`:

```swift
    /// itemNotFound → notFound; any other non-success → failed(status); success → a synced item
    /// anywhere in the result → rejected(.synchronizableItem) (checked first: one is enough);
    /// more than one item → rejected(.multipleItems); exactly one with data and ref → found;
    /// success with no items or an item missing data/ref → failed(errSecSuccess) (never "absent":
    /// that would mint).
    static func mapRead(status: OSStatus, items: [[String: Any]]?) -> ReadResult {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecSuccess:
            guard let items, !items.isEmpty else { return .failed(errSecSuccess) }
            if items.contains(where: isSynchronizable) { return .rejected(.synchronizableItem) }
            if items.count > 1 { return .rejected(.multipleItems(count: items.count)) }
            guard let data = items[0][kSecValueData as String] as? Data,
                  let persistentRef = items[0][kSecValuePersistentRef as String] as? Data
            else { return .failed(errSecSuccess) }
            return .found(data, persistentRef: persistentRef)
        default:
            return .failed(status)
        }
    }

    /// `kSecAttrSynchronizable` comes back as a CFBoolean / NSNumber on synced items and is absent
    /// (or 0) on device-local ones.
    static func isSynchronizable(_ attributes: [String: Any]) -> Bool {
        guard let value = attributes[kSecAttrSynchronizable as String] else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return false
    }
```

Update the header comment of `live` to say reads see every item and refuse duplicates and synced copies.

- [ ] **Step 4: Implement `InMemoryKeychain`**

In `Sources/ReTiCAKeychain/InMemoryKeychain.swift`: `Stored` gains `var synchronizable: Bool`; `init` stores `synchronizable: false`; `set` gains the parameter:

```swift
    /// Plants (or with nil, removes) an item at exactly this location and account.
    /// `synchronizable` models an iCloud-synced copy (something `add` never writes).
    public func set(_ data: Data?, at location: Location, account: String = "", synchronizable: Bool = false) {
        locked {
            let key = Key(location: location, account: account)
            if let data {
                items[key] = Stored(data: data, ref: makeRef(), synchronizable: synchronizable)
            } else {
                items[key] = nil
            }
        }
    }
```

`read` mirrors the live order:

```swift
    private func read(_ location: Location) -> KeychainOps.ReadResult {
        locked {
            if let status = readFailures[location] { return .failed(status) }
            let matches = matchingKeys(location).compactMap { items[$0] }
            guard !matches.isEmpty else { return .notFound }
            if matches.contains(where: \.synchronizable) { return .rejected(.synchronizableItem) }
            if matches.count > 1 { return .rejected(.multipleItems(count: matches.count)) }
            return .found(matches[0].data, persistentRef: matches[0].ref)
        }
    }
```

`add` stores `synchronizable: false`. Update the header comment: a read returns the one match, or `rejected` when several match or any is synchronizable; and add the fidelity note: "An unentitled named group returns `notFound` here where the real Keychain returns `-34018` `errSecMissingEntitlement`."

- [ ] **Step 5: Implement the `IdentityKeychain` mapping**

In `Sources/ReTiCAKeychain/IdentityKeychain.swift` add to `Failure`:

```swift
        /// More than one item at this location. Nothing is read, minted, migrated, deleted or imported.
        case ambiguousItems(location: Location, count: Int)
        /// An item at this location is iCloud-synchronizable. Fails closed the same way.
        case synchronizableItem(location: Location)
```

Add the helper:

```swift
    /// The failure a rejected read means at this location.
    static func failure(for rejection: KeychainOps.ReadRejection, at location: Location) -> Failure {
        switch rejection {
        case let .multipleItems(count): return .ambiguousItems(location: location, count: count)
        case .synchronizableItem: return .synchronizableItem(location: location)
        }
    }
```

Then handle `.rejected` at every `switch ops.read(...)`:
- `load` rule 1 (`shared`): `case let .rejected(r): return .failed(failure(for: r, at: shared))`.
- `load` rule 2 (each `location`): `case let .rejected(r): return .failed(failure(for: r, at: location))`.
- `migrate` `.duplicate` re-read and `.added` re-read: `case let .rejected(r): return .failed(failure(for: r, at: shared))` (the legacy item is kept).
- `rereadWinner`: same, at `shared`.
- `importIdentity` step 3 named loop: `case let .rejected(r): return .failed(failure(for: r, at: location))`; step 4 duplicate re-read and step 5 verify re-read: `case let .rejected(r): return .failed(failure(for: r, at: shared))`.
- `probeForUnexpectedItems` (group-less `anyGroup`): `case .rejected(.multipleItems): return .unexpectedItem(service: service)`; `case .rejected(.synchronizableItem): return .synchronizableItem(location: anyGroup)`.
- `removeLegacyCopies`: unchanged (`if case let .found` already ignores everything else).

Extend the header's anti-rotation comment: "a location holding more than one item, or any iCloud-synchronizable item, fails closed the same way".

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening --filter ReTiCAKeychainTests`
Expected: PASS, every existing test still green.

- [ ] **Step 7: Mutation check (sub-batches; revert each by hand)**

Batch A (unmasked, one run): in `mapRead` swap the order of the synchronizable and count checks → the NSNumber two-item case in `liveStatusMapping` fails; in `InMemoryKeychain.read` drop the `synchronizable` check → `inMemoryRejectsMultipleAndSynchronizableItems`, `loadFailsClosedOnASynchronizableSharedItem`, `loadProbeSeesASynchronizableStray`, `importRefusesOnASynchronizableStray` fail; in `probeForUnexpectedItems` map `.multipleItems` to `.synchronizableItem` → `loadProbeWithSeveralStraysIsAnUnexpectedItem` fails; in `readQuery` set `kSecMatchLimitOne` → `liveQueriesAreScopedAndSeeEveryItem` fails.
Batch B (separate run): in `load` rule 1 treat `.rejected` like `.notFound` (`break`) → `loadFailsClosedOnTwoItemsAtTheSharedLocation` fails on the outcome and, via `loadOrCreate`, on `addCount`; in `migrate` `.duplicate` branch treat `.rejected` as `.loaded` of the legacy seed → `migrationDuplicateRereadRejectedFails…` fails; in `importIdentity` step 5 treat `.rejected` as `.imported(candidate)` → `importVerifyRereadRejectedFails` fails; in `isSynchronizable` return false for `NSNumber` → the `NSNumber` `#expect`s fail.
Revert every mutation by hand, run again: PASS. `git diff` shows only intended changes.

- [ ] **Step 8: Commit**

```bash
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening add Sources/ReTiCAKeychain Tests/ReTiCAKeychainTests
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening commit -F <message file>
```
Message: `feat: Keychain reads see every item and refuse duplicates or synced copies`.

---

### Task 2: A probe hit on the shared service re-reads

**Files:**
- Modify: `Sources/ReTiCAKeychain/IdentityKeychain.swift`
- Modify: `Sources/ReTiCAKeychain/InMemoryKeychain.swift`
- Create: `Tests/ReTiCAKeychainTests/IdentityKeychainProbeTests.swift`

**Interfaces:**
- Consumes: Task 1's `failure(for:at:)`, `.rejected`.
- Produces: `IdentityKeychain.ProbeResult` (internal: `clear`, `hit(service:)`, `failed(Failure)`), `probe(shared:legacy:ops:)` replacing `probeForUnexpectedItems`, `InMemoryKeychain.onBeforeRead(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCAKeychainTests/IdentityKeychainProbeTests.swift`:

```swift
import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacy = IdentityKeychain.Location(service: "app.identity", accessGroup: "TEAMID.co.example.app")
private let sharedAnyGroup = IdentityKeychain.Location(service: shared.service, accessGroup: nil)
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Spec 2026-09-29 §4.3: when the group-less probe hits the SHARED service, re-read the shared
/// location — the other app may have written it between rule 1 and the probe.
@Suite("IdentityKeychain probe re-read")
struct IdentityKeychainProbeTests {

    /// The first-launch race: shared absent at rule 1, present by the time the probe runs.
    @Test func loadResolvesTheRaceWhenTheProbeHitsTheSharedService() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain()
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { location in
            reads.append(location)
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.addCount == 0)
        // rule 1 shared, rule 2 legacy, probe shared-any, probe (nothing else: the re-read of shared)
        #expect(reads.values.last == shared)
        #expect(reads.values.filter { $0 == shared }.count == 2)
    }

    @Test func loadOrCreateDoesNotMintWhenTheRaceIsResolved() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
            }
        }
        #expect(IdentityKeychain.loadOrCreate(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.addCount == 0)
    }

    /// The re-read also finishes an interrupted migration it now sees.
    @Test func loadRaceRereadRemovesAByteEqualLegacyLeftover() {
        let (identity, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
                keychain.set(data, at: legacy)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops) == .loaded(identity))
        #expect(keychain.item(at: legacy) == nil)
    }

    @Test func loadRaceWithACorruptSharedItemFails() {
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(garbage, at: shared)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.corrupt(location: shared)))
        #expect(keychain.addCount == 0)
    }

    @Test func loadRaceWithTwoSharedItemsFails() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(a, at: shared)
                keychain.set(b, at: shared, account: "second")
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.ambiguousItems(location: shared, count: 2)))
        #expect(keychain.addCount == 0)
    }

    /// A same-service item in a group we don't name is still a stray: the re-read finds nothing.
    @Test func loadStillFailsClosedOnASharedServiceItemInAnotherGroup() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: shared.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([stray: data])
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: shared.service)))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: stray) == data)
    }

    /// A read error on the re-read is a failure, never absent.
    @Test func loadRaceRereadErrorFails() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
                keychain.failRead(at: shared, status: -25308)
            }
        }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.readFailed(location: shared, status: -25308)))
        #expect(keychain.addCount == 0)
    }

    /// A hit on a LEGACY service never triggers the shared re-read.
    @Test func loadLegacyServiceHitDoesNotRereadShared() {
        let (_, data) = makeSeed()
        let stray = IdentityKeychain.Location(service: legacy.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([stray: data])
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { reads.append($0) }
        #expect(IdentityKeychain.load(shared: shared, legacy: [legacy], ops: keychain.ops)
                == .failed(.unexpectedItem(service: legacy.service)))
        #expect(reads.values.filter { $0 == shared }.count == 1)
    }

    @Test func importAnswersIdentityPresentWhenTheProbeHitsTheSharedService() {
        let (_, data) = makeSeed()
        let (_, candidate) = makeSeed()
        let keychain = InMemoryKeychain()
        keychain.onBeforeRead { location in
            if location == sharedAnyGroup, keychain.item(at: shared) == nil {
                keychain.set(data, at: shared)
            }
        }
        #expect(IdentityKeychain.importIdentity(privateKey: candidate, shared: shared, legacy: [legacy], ops: keychain.ops)
                == .identityPresent(service: shared.service))
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == data)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening --filter IdentityKeychainProbeTests`
Expected: compile error (`onBeforeRead` does not exist).

- [ ] **Step 3: Add `onBeforeRead` to `InMemoryKeychain`**

Next to `beforeAdd`:

```swift
    private var beforeRead: (@Sendable (Location) -> Void)?
    /// Runs outside the lock before every `read`, so a hook may `set` (e.g. another app writing
    /// the shared item between rule 1 and the probe).
    public func onBeforeRead(_ hook: @escaping @Sendable (Location) -> Void) { locked { beforeRead = hook } }
```

At the top of `read`:

```swift
        let hook = locked { beforeRead }
        hook?(location)
        return locked { ... existing body ... }
```

Update the header comment (`onBeforeAdd` and `onBeforeRead` run outside the lock).

- [ ] **Step 4: Implement the probe result and re-read**

In `IdentityKeychain.swift`:

```swift
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
```

`load` rule 3:

```swift
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
```

`importIdentity` step 3 (any group):

```swift
        switch probe(shared: shared, legacy: legacy, ops: ops) {
        case .clear: break
        case let .hit(service): return .identityPresent(service: service)
        case let .failed(failure): return .failed(failure)
        }
```

Delete `probeForUnexpectedItems`. Update the `load` doc comment rule 3 to describe the re-read.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening --filter ReTiCAKeychainTests`
Expected: PASS (the whole Keychain suite).

- [ ] **Step 6: Mutation check (sub-batches; revert by hand)**

Batch A: remove the `guard service == shared.service` (re-read on every hit) → `loadLegacyServiceHitDoesNotRereadShared` fails; in the `.found` branch skip `removeLegacyCopies` → `loadRaceRereadRemovesAByteEqualLegacyLeftover` fails; in `importIdentity` treat `.hit` as `break` → `importAnswersIdentityPresentWhenTheProbeHitsTheSharedService` fails on outcome and `addCount`.
Batch B: in the re-read's `.notFound` branch return `.absent` → `loadStillFailsClosedOnASharedServiceItemInAnotherGroup` fails (and `loadOrCreate` would mint — pinned by the existing stray tests' `addCount`); in the `.found` branch skip the `Identity(privateKey:)` guard by returning `.failed(.corrupt)` only for `data.isEmpty` → `loadRaceWithACorruptSharedItemFails` fails.
Revert by hand; run: PASS; `git diff` clean of mutations.

- [ ] **Step 7: Commit**

Message: `fix: a probe hit on the shared service re-reads it, resolving the first-launch race`.

---

### Task 3: `legacyConflicts`

**Files:**
- Modify: `Sources/ReTiCAKeychain/IdentityKeychain.swift`
- Create: `Tests/ReTiCAKeychainTests/IdentityKeychainConflictTests.swift`

**Interfaces:**
- Consumes: Task 1's `failure(for:at:)`, `firstUnscoped`.
- Produces: `IdentityKeychain.LegacyConflict`, `IdentityKeychain.ConflictOutcome`, `IdentityKeychain.legacyConflicts(shared:legacy:ops:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import ReTiCA
@testable import ReTiCAKeychain

private let shared = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAMID.co.example.reticulum.identity")
private let legacyA = IdentityKeychain.Location(service: "a.identity", accessGroup: "TEAMID.co.example.a")
private let legacyB = IdentityKeychain.Location(service: "b.identity", accessGroup: "TEAMID.co.example.b")
private let garbage = Data(repeating: 0xAB, count: 63)

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

/// Spec 2026-09-29 §4.4: a read-only report of legacy items whose identity differs from the one
/// that would win (the shared item, or the first legacy item when the shared one is absent).
@Suite("IdentityKeychain.legacyConflicts")
struct IdentityKeychainConflictTests {

    @Test func noItemsAnywhereIsNone() {
        let keychain = InMemoryKeychain()
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA, legacyB], ops: keychain.ops) == .none)
        #expect(keychain.addCount == 0)
    }

    @Test func sharedOnlyAndByteEqualLegacyAreNone() {
        let (_, data) = makeSeed()
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: data]).ops) == .none)
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: data, legacyA: data]).ops) == .none)
    }

    @Test func aLegacyItemDifferingFromSharedIsAConflict() {
        let (sharedIdentity, sharedData) = makeSeed()
        let (otherIdentity, otherData) = makeSeed()
        let sameData = sharedData
        let keychain = InMemoryKeychain([shared: sharedData, legacyA: otherData, legacyB: sameData])
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA, legacyB], ops: keychain.ops)
                == .conflicts(sharedHash: sharedIdentity.hash,
                              legacy: [.init(location: legacyA, identityHash: otherIdentity.hash)]))
        // Read-only: nothing added or removed.
        #expect(keychain.addCount == 0)
        #expect(keychain.item(at: shared) == sharedData)
        #expect(keychain.item(at: legacyA) == otherData)
        #expect(keychain.item(at: legacyB) == sameData)
    }

    /// Shared absent: the first legacy item is the reference (it would win the migration).
    @Test func withSharedAbsentTheFirstLegacyIdentityIsTheReference() {
        let (_, first) = makeSeed()
        let (second, secondData) = makeSeed()
        let keychain = InMemoryKeychain([legacyA: first, legacyB: secondData])
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA, legacyB], ops: keychain.ops)
                == .conflicts(sharedHash: nil, legacy: [.init(location: legacyB, identityHash: second.hash)]))
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops) == .none)
        #expect(keychain.addCount == 0)
    }

    @Test func corruptItemsFail() {
        let (_, data) = makeSeed()
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: garbage]).ops)
                == .failed(.corrupt(location: shared)))
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: InMemoryKeychain([shared: data, legacyA: garbage]).ops)
                == .failed(.corrupt(location: legacyA)))
    }

    @Test func readErrorsAndRejectionsFail() {
        let (_, a) = makeSeed()
        let (_, b) = makeSeed()
        let keychain = InMemoryKeychain([shared: a])
        keychain.failRead(at: legacyA, status: -25308)
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops)
                == .failed(.readFailed(location: legacyA, status: -25308)))
        keychain.clearFailures()
        keychain.set(b, at: legacyA)
        keychain.set(a, at: legacyA, account: "second")
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops)
                == .failed(.ambiguousItems(location: legacyA, count: 2)))
    }

    @Test func unscopedLocationsAreRejectedBeforeAnyRead() {
        let unscoped = IdentityKeychain.Location(service: legacyA.service, accessGroup: nil)
        let keychain = InMemoryKeychain()
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { reads.append($0) }
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [unscoped], ops: keychain.ops)
                == .failed(.invalidLocation(unscoped)))
        #expect(reads.values.isEmpty)
    }

    @Test func aSharedAliasInLegacyIsIgnored() {
        let (_, data) = makeSeed()
        let keychain = InMemoryKeychain([shared: data])
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [shared, legacyA], ops: keychain.ops) == .none)
    }

    /// Conflicts name their locations; strays in unnamed groups are `load`'s job, not this query's.
    @Test func theGrouplessProbeIsNotRun() {
        let (_, data) = makeSeed()
        let (_, stray) = makeSeed()
        let elsewhere = IdentityKeychain.Location(service: legacyA.service, accessGroup: "TEAMID.co.example.wrong")
        let keychain = InMemoryKeychain([shared: data, elsewhere: stray])
        let reads = Collector<IdentityKeychain.Location>()
        keychain.onBeforeRead { reads.append($0) }
        #expect(IdentityKeychain.legacyConflicts(shared: shared, legacy: [legacyA], ops: keychain.ops) == .none)
        #expect(reads.values.allSatisfy { $0.accessGroup != nil })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/keychain-hardening --filter IdentityKeychainConflictTests`
Expected: compile error (`legacyConflicts`, `ConflictOutcome`, `LegacyConflict` do not exist).

- [ ] **Step 3: Implement**

In `IdentityKeychain.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify pass**

Run the Keychain suite. Expected: PASS.

- [ ] **Step 5: Mutation check**

Batch A: append a conflict whenever `reference != nil`, ignoring the hash comparison → `sharedOnlyAndByteEqualLegacyAreNone` and `aLegacyItemDifferingFromSharedIsAConflict` (legacyB) fail; set `reference` from the shared read but not `sharedHash` → `aLegacyItemDifferingFromSharedIsAConflict` fails on `sharedHash`; run the probe at the end → `theGrouplessProbeIsNotRun` fails.
Batch B: skip the `firstUnscoped` guard → `unscopedLocationsAreRejectedBeforeAnyRead` fails; treat a corrupt legacy item as `continue` → `corruptItemsFail` (legacyA) fails.
Revert by hand; PASS.

- [ ] **Step 6: Commit**

Message: `feat: legacyConflicts reports a differing legacy identity without writing`.

---

### Task 4: `IdentityBackup` base32 codec

**Files:**
- Create: `Sources/ReTiCAKeychain/IdentityBackup.swift`
- Create: `Tests/ReTiCAKeychainTests/IdentityBackupTests.swift`

**Interfaces:**
- Produces: `IdentityBackup.base32(_:)`, `IdentityBackup.decodeBase32(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ReTiCAKeychain

/// RFC 4648 §10 vectors — what Python's base64.b32encode / b32decode produce and accept.
@Suite("IdentityBackup base32")
struct IdentityBackupTests {
    private let vectors: [(String, String)] = [
        ("", ""), ("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="),
        ("foob", "MZXW6YQ="), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI======"),
    ]

    @Test func encodesTheRFCVectors() {
        for (plain, encoded) in vectors {
            #expect(IdentityBackup.base32(Data(plain.utf8)) == encoded)
        }
    }

    @Test func decodesWithAndWithoutPadding() {
        for (plain, encoded) in vectors {
            #expect(IdentityBackup.decodeBase32(encoded) == Data(plain.utf8))
            let unpadded = String(encoded.filter { $0 != "=" })
            #expect(IdentityBackup.decodeBase32(unpadded) == Data(plain.utf8))
        }
    }

    @Test func roundTripsAn64ByteKey() {
        var bytes = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { bytes[i] = UInt8((i * 37 + 11) & 0xFF) }
        let data = Data(bytes)
        let text = IdentityBackup.base32(data)
        #expect(text.count == 104)          // 64 bytes → 103 symbols + 1 pad
        #expect(text.hasSuffix("="))
        #expect(IdentityBackup.decodeBase32(text) == data)
    }

    @Test func rejectsNonCanonicalInput() {
        #expect(IdentityBackup.decodeBase32("mzxw6===") == nil)      // lowercase
        #expect(IdentityBackup.decodeBase32("MZXW6Y=") == nil)       // wrong pad count
        #expect(IdentityBackup.decodeBase32("MZXW6YTBO") == nil)     // impossible length (remainder 1)
        #expect(IdentityBackup.decodeBase32("MZXW6YR=") == nil)      // non-zero trailing bits
        #expect(IdentityBackup.decodeBase32("MZXW6===\n") == nil)    // callers trim; the codec does not
        #expect(IdentityBackup.decodeBase32("MZXW1===") == nil)      // '1' is not in the alphabet
        #expect(IdentityBackup.decodeBase32("========") == nil)      // padding only
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error (`IdentityBackup` missing).

- [ ] **Step 3: Implement** `Sources/ReTiCAKeychain/IdentityBackup.swift`:

```swift
import Foundation

/// Text and file forms of a Reticulum identity backup, shared by every adopting app so one
/// backup restores in any of them. Pure functions — callers own secret handling. Never log the
/// inputs or outputs.
public enum IdentityBackup {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// RFC 4648 base32, uppercase, '=' padded — byte-identical to Python's base64.b32encode
    /// (what Sideband's identity restore and `rnid -B` decode).
    public static func base32(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity((data.count + 4) / 5 * 8)
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        while out.count % 8 != 0 { out.append(UInt8(ascii: "=")) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Strict RFC 4648 base32 decode — the inverse of `base32`, and of Python's
    /// `base64.b32decode` (no casefold): uppercase alphabet only; '=' padding must be exactly right
    /// or entirely absent; impossible lengths and non-zero trailing bits are rejected. It does not
    /// trim whitespace (callers do). Never log the input or the output.
    public static func decodeBase32(_ text: String) -> Data? {
        var symbols = Array(text.utf8)
        var padCount = 0
        while symbols.last == UInt8(ascii: "=") {
            symbols.removeLast()
            padCount += 1
        }
        let remainder = symbols.count % 8
        // 8 symbols = 5 bytes; a final group of 2, 4, 5 or 7 symbols = 1, 2, 3 or 4 bytes.
        guard [0, 2, 4, 5, 7].contains(remainder) else { return nil }
        if padCount > 0 {
            guard padCount == (8 - remainder) % 8 else { return nil }
        }
        var out = [UInt8]()
        out.reserveCapacity(symbols.count * 5 / 8)
        var buffer = 0, bits = 0
        for symbol in symbols {
            guard let value = alphabet.firstIndex(of: symbol) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        // Canonical input only: the spare bits of the last symbol must be zero.
        guard buffer == 0 else { return nil }
        return Data(out)
    }
}
```

Note: `"========"` → after stripping, 0 symbols with padCount 8 → `padCount == (8 - 0) % 8 == 0` is false → nil. `"MZXW6Y="` → remainder 6 → nil. `"MZXW6YTBO"` → remainder 1 → nil.

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Mutation check**

Batch A: drop the `guard buffer == 0` → `rejectsNonCanonicalInput` (`MZXW6YR=`) fails; drop the padCount check → `MZXW6Y=` and `========` cases fail; lowercase the alphabet lookup (`symbol | 0x20`) → the lowercase case fails.
Batch B: in `base32` pad to a multiple of 4 instead of 8 → `encodesTheRFCVectors` fails; in `decodeBase32` allow remainder 1 → `MZXW6YTBO` case fails.
Revert by hand; PASS.

- [ ] **Step 6: Commit**

Message: `feat: IdentityBackup base32 codec shared by adopting apps`.

---

## Final whole-branch review

After Task 4: the full ReTiCA suite (`swift test --package-path <worktree>`; expect the pre-existing known issue only), then the final Opus review over `main..HEAD`, one fix wave, one re-review. Then the user approves the fast-forward merge into ReTiCA `main`, and the Nbhd build note (spec §6) is appended to `/Users/ell/development/ios/apps/Nbhd/docs/STATUS.md` follow-ups by the controller.
