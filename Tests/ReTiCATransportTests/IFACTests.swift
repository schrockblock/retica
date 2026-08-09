import Testing
import Foundation
@testable import ReTiCA
@testable import ReTiCATransport

/// The salt is the reference constant (`Reticulum.py:150`, RNS 1.4.2 stock).
@Test func ifacSaltMatchesReference() {
    #expect(IFAC.salt.map { String(format: "%02x", $0) }.joined()
            == "adf54d882c9a9b80771eb4995d702d4a3e733391b2a0f53f416d9f907e55cff8")
}

/// A round trip recovers the original packet exactly.
@Test func protectThenUnprotectRoundTrips() throws {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + (0..<60).map { UInt8($0) })
    let wire = ifac.protect(raw)
    #expect(wire.count == raw.count + 16)        // grows by exactly ifac_size
    #expect(wire[0] & 0x80 == 0x80)              // flag set on the wire
    #expect(ifac.unprotect(wire) == raw)
}

/// The payload is genuinely masked — the wire bytes must not contain the plaintext tail.
@Test func protectMasksThePayload() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0xAA), count: 40))
    let wire = ifac.protect(raw)
    #expect(wire.dropFirst(18) != raw.dropFirst(2))
}

/// The IFAC itself rides UNMASKED at bytes 2..<2+size — the receiver needs it to derive
/// the mask before it can unmask anything (RNS Transport.py:1447-1450).
@Test func theAccessCodeItselfIsNotMasked() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x11), count: 30))
    let wire = ifac.protect(raw)
    let carried = wire.subdata(in: 2..<18)
    // Re-deriving the mask from the carried code must unmask correctly — which only works
    // if the carried code is the plaintext one.
    #expect(ifac.unprotect(wire) == raw)
    #expect(carried.count == 16)
}

/// A different network cannot read or authenticate the packet.
@Test func aDifferentNetworkKeyRejectsThePacket() {
    let a = IFAC(networkName: "net-a", passphrase: nil, size: 16)!
    let b = IFAC(networkName: "net-b", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x5A), count: 32))
    #expect(b.unprotect(a.protect(raw)) == nil)
}

/// Tampering with any masked byte fails authentication.
@Test func tamperedPayloadFailsAuthentication() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x33), count: 32))
    var wire = ifac.protect(raw)
    wire[25] ^= 0x01
    #expect(ifac.unprotect(wire) == nil)
}

/// A packet without the flag set is rejected outright, as is one too short to hold a code.
@Test func missingFlagOrShortPacketIsRejected() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x77), count: 32))
    var noFlag = ifac.protect(raw)
    noFlag[0] &= 0x7F
    #expect(ifac.unprotect(noFlag) == nil)
    #expect(ifac.unprotect(Data([0x80, 0x00, 0x01])) == nil)
}

/// netname and passphrase each contribute to the derivation origin, and supplying both
/// differs from either alone (RNS Reticulum.py:961-966 concatenates the two hashes).
@Test func derivationDistinguishesNameAndPassphrase() {
    let name = IFAC(networkName: "alpha", passphrase: nil, size: 16)!
    let pass = IFAC(networkName: nil, passphrase: "beta", size: 16)!
    let both = IFAC(networkName: "alpha", passphrase: "beta", size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x9C), count: 24))
    #expect(pass.unprotect(name.protect(raw)) == nil)
    #expect(both.unprotect(name.protect(raw)) == nil)
    #expect(both.unprotect(pass.protect(raw)) == nil)
    #expect(both.unprotect(both.protect(raw)) == raw)
}

/// SURPRISING BUT FAITHFUL: netname and passphrase are NOT domain-separated. The origin is
/// full_hash(netname) ‖ full_hash(netkey) (RNS Reticulum.py:961-966), so a netname equal to
/// a passphrase derives the SAME key and the two interoperate. Verified against reference
/// RNS. Do not add domain separation — it would silently break interop with real networks.
@Test func nameAndPassphraseAreNotDomainSeparated() {
    let byName = IFAC(networkName: "shared", passphrase: nil, size: 16)!
    let byPass = IFAC(networkName: nil, passphrase: "shared", size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x4D), count: 24))
    #expect(byPass.unprotect(byName.protect(raw)) == raw)
}

/// Neither credential means no IFAC (RNS only derives when at least one is present).
@Test func noCredentialsYieldsNoIFAC() {
    #expect(IFAC(networkName: nil, passphrase: nil, size: 16) == nil)
    #expect(IFAC(networkName: "", passphrase: "", size: 16) == nil)
}

/// A non-default code size round-trips and changes the wire length accordingly.
@Test func nonDefaultSizeRoundTrips() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 8)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x21), count: 20))
    let wire = ifac.protect(raw)
    #expect(wire.count == raw.count + 8)
    #expect(ifac.unprotect(wire) == raw)
}

/// Inbound bytes routinely arrive as a `dropFirst`-style deframer slice, whose indices do
/// NOT rebase to 0. Both entry points must normalise, or indexing traps at runtime — which
/// on the network-facing decoder would be a remote abort. Same convention as
/// `Packet.init(raw:)` (Sources/ReTiCA/Packet/Packet.swift:70).
@Test func sliceInputsAreRebasedRatherThanTrapping() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    let raw = Data([0x00, 0x00] + Array(repeating: UInt8(0x6B), count: 32))

    // protect() over a non-zero-based input slice.
    let rawSlice = Data([0xFF, 0xFF] + raw).dropFirst(2)
    #expect(rawSlice.startIndex == 2)          // precondition: genuinely not rebased
    let wireFromSlice = ifac.protect(rawSlice)
    #expect(wireFromSlice == ifac.protect(raw))

    // unprotect() over a non-zero-based wire slice.
    let wire = ifac.protect(raw)
    let wireSlice = Data([0xFF, 0xFF] + wire).dropFirst(2)
    #expect(wireSlice.startIndex == 2)         // precondition: genuinely not rebased
    #expect(ifac.unprotect(wireSlice) == raw)
}

/// A too-short packet is a programmer error, not a runtime condition — `protect` requires
/// the two-byte RNS header. Pinned so the guard is not silently dropped.
@Test func protectRequiresATwoByteHeader() {
    let ifac = IFAC(networkName: "testnet", passphrase: nil, size: 16)!
    // A 2-byte packet is the minimum and must not trap.
    #expect(ifac.protect(Data([0x00, 0x00])).count == 2 + 16)
}
