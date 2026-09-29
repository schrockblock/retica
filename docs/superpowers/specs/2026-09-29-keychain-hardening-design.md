# ReTiCAKeychain Hardening — Design (pointer)

**Date:** 2026-09-29
**Status:** Approved
**Scope:** `ReTiCAKeychain` only.

The design lives in the ReTiCaMsgr repository, §4 of
`/Users/ell/development/ios/apps/ReTiCaMsgr/docs/superpowers/specs/2026-09-29-shared-identity-adoption-design.md`
(the messaging app's adoption of the shared identity, whose Part A is this hardening). Summary:

1. **Reads see every item.** `KeychainOps.read` queries with match-limit-all and synchronizable-any
   and returns `rejected(.multipleItems(count:))` or `rejected(.synchronizableItem)` instead of
   silently picking one. `IdentityKeychain` maps those to `Failure.ambiguousItems(location:count:)`
   and `Failure.synchronizableItem(location:)` and fails closed at every read site.
2. **The probe inherits it**, so synchronizable strays are seen too.
3. **A probe hit on the shared service re-reads the shared location**, resolving the first-launch
   race (`loaded`) instead of a spurious `unexpectedItem`.
4. **`legacyConflicts(shared:legacy:ops:)`** — a read-only report of legacy items whose identity
   differs from the one that would win.
5. **`IdentityBackup`** — the RFC 4648 base32 codec (Python-compatible) for identity backups, so
   every adopting app accepts the same text form.

Plan: `docs/superpowers/plans/2026-09-29-keychain-hardening.md`.

## Amendments at planning time

1. §4.1 says a successful read with an empty result is `notFound`; the plan fails it closed
   (`.failed(errSecSuccess)`) like a missing data or ref — `SecItemCopyMatching` never returns
   success with an empty array, and "unknown" must never read as "absent".
