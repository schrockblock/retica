import Foundation
import ReTiCA

/// Interface Access Code — authenticates and masks packets on a named/passphrase-protected
/// network segment.  Mirrors the algorithm in RNS `Reticulum.py:958-973` (key derivation)
/// and `Transport.py:1069-1104` / `1440-1476` (protect / unprotect). Line numbers are for
/// the pinned cross-validation reference, RNS 1.4.2.
///
/// ### Bit-7 asymmetry — do NOT "fix" this
/// Outbound: byte 0 is masked then OR'd with `0x80` (`(x ^ mask[0]) | 0x80`).
/// Inbound:  byte 0 is XOR'd back (`x ^ mask[0]`), then bit 7 is cleared with `& 0x7f`.
/// These are NOT inverses when `mask[0]` has bit 7 set, so the recovered bit 7 may be
/// wrong.  That is harmless and intended: `new_header` clears it before the signature is
/// computed, and the sender signed the original packet whose bit 7 was already clear.
public struct IFAC: Equatable, Sendable {

    // MARK: — Public interface

    /// Reticulum's IFAC key-derivation salt (`Reticulum.py:150`, RNS 1.4.2).
    public static let salt: Data = {
        let bytes: [UInt8] = [
            0xad, 0xf5, 0x4d, 0x88, 0x2c, 0x9a, 0x9b, 0x80,
            0x77, 0x1e, 0xb4, 0x99, 0x5d, 0x70, 0x2d, 0x4a,
            0x3e, 0x73, 0x33, 0x91, 0xb2, 0xa0, 0xf5, 0x3f,
            0x41, 0x6d, 0x9f, 0x90, 0x7e, 0x55, 0xcf, 0xf8,
        ]
        return Data(bytes)
    }()

    /// Derive an IFAC from a network name and/or passphrase.
    ///
    /// Returns `nil` when both credentials are absent or empty, or when `size` is outside
    /// `1...64` (`Reticulum.py:958`).
    ///
    /// - Parameters:
    ///   - networkName:  The interface's `ifac_netname` (optional).
    ///   - passphrase:   The interface's `ifac_netkey`  (optional).
    ///   - size:         Number of bytes of the access code to carry on the wire. There is no
    ///                   universal default: RNS sets `DEFAULT_IFAC_SIZE` PER INTERFACE TYPE —
    ///                   16 for TCP/UDP/Auto/BLE but 8 for KISS/Serial/RNode/AX25. Callers must
    ///                   pass the value for the interface in hand rather than assuming 16.
    public init?(networkName: String?, passphrase: String?, size: Int) {
        guard (1...64).contains(size) else { return nil }

        // Reticulum.py:958-966: build origin from the non-empty credentials.
        var origin = Data()
        if let name = networkName, !name.isEmpty {
            origin.append(Crypto.fullHash(Data(name.utf8)))
        }
        if let pass = passphrase, !pass.isEmpty {
            origin.append(Crypto.fullHash(Data(pass.utf8)))
        }
        guard !origin.isEmpty else { return nil }

        // Reticulum.py:967-972: derive a 64-byte key; seed = LAST 32 bytes (Ed25519 half).
        // RNS private key layout: X25519(32) ‖ Ed25519(32) — so suffix(32) is the Ed25519 seed.
        let originHash = Crypto.fullHash(origin)
        let key = Crypto.hkdf(length: 64, derivedFrom: originHash, salt: Self.salt, context: nil)
        // The LAST 32 bytes; prefix(32) would be wrong. Rebased via Data(...) because
        // `suffix` returns a non-zero-based slice, and storing a slice in a long-lived
        // struct is an index trap waiting for a future caller.
        let signingSeed = Data(key.suffix(32))

        self.key  = key
        self.seed = signingSeed
        self.size = size
    }

    // MARK: — protect  (Transport.py:1069-1104)

    /// Authenticate and mask `raw`, returning the wire bytes (length = `raw.count + size`).
    ///
    /// - Precondition: `raw` must begin with the two-byte RNS header (bytes 0 and 1).
    public func protect(_ rawInput: Data) -> Data {
        let raw = Data(rawInput) // normalize to 0-based indices
        // A packet shorter than the RNS header is a programmer error, not a runtime
        // condition — surface it with a message rather than an opaque index trap.
        precondition(raw.count >= 2, "IFAC.protect requires the 2-byte RNS header, got \(raw.count)")

        // Sign the original packet — access code = last `size` bytes of the 64-byte signature.
        let ifac = Data(DeterministicSigner.sign(message: raw, seed: seed).suffix(size))

        // Generate the mask over the full output length.
        let mask = Crypto.hkdf(length: raw.count + size,
                               derivedFrom: ifac, salt: key, context: nil)

        // Assemble with IFAC flag set (Transport.py:1081).
        let newHeader = Data([raw[0] | 0x80, raw[1]])
        let newRaw    = newHeader + ifac + raw.dropFirst(2)

        // Mask byte by byte:
        //   i == 0          → mask then force IFAC flag (Transport.py:1091)
        //   i == 1 or i > size+1 → mask normally (Transport.py:1094)
        //   2 ≤ i ≤ size+1  → leave IFAC unmasked   (Transport.py:1096-1097)
        var masked = Data(capacity: newRaw.count)
        for (i, byte) in newRaw.enumerated() {
            if i == 0 {
                masked.append((byte ^ mask[i]) | 0x80)
            } else if i == 1 || i > size + 1 {
                masked.append(byte ^ mask[i])
            } else {
                masked.append(byte)        // IFAC region left unmasked
            }
        }
        return masked
    }

    // MARK: — unprotect  (Transport.py:1440-1476)

    /// Authenticate and unmask `wire`, returning the original raw bytes on success, or `nil`
    /// if the packet is too short, the IFAC flag is missing, or the code doesn't match.
    ///
    /// Returns `nil` on every rejection path; Transport drops silently.
    public func unprotect(_ wireInput: Data) -> Data? {
        // Normalize to 0-based indices. Inbound bytes routinely arrive as a `dropFirst`-style
        // deframer slice, whose indices do NOT rebase — indexing one directly traps, which on
        // the network-facing decoder would be a remote abort. Same convention as
        // `Packet.init(raw:)` (Sources/ReTiCA/Packet/Packet.swift:70).
        let wire = Data(wireInput)

        // Guard: must be long enough to hold a header plus the code (Transport.py:1441, 1445).
        guard wire.count > 2 + size else { return nil }
        // Guard: flag must be set (Transport.py:1444).
        guard wire[0] & 0x80 == 0x80 else { return nil }

        // Extract the unmasked IFAC from bytes 2..<2+size (Transport.py:1447).
        let ifac = wire.subdata(in: 2..<(2 + size))

        // Generate the mask over the wire length (Transport.py:1450).
        let mask = Crypto.hkdf(length: wire.count, derivedFrom: ifac, salt: key, context: nil)

        // Unmask:
        //   i ≤ 1 or i > size+1 → XOR with mask (Transport.py:1456)
        //   2 ≤ i ≤ size+1      → leave IFAC in place (Transport.py:1458)
        var unmasked = Data(capacity: wire.count)
        for (i, byte) in wire.enumerated() {
            if i <= 1 || i > size + 1 {
                unmasked.append(byte ^ mask[i])
            } else {
                unmasked.append(byte)
            }
        }

        // Clear the IFAC flag (Transport.py:1464) — note: this may differ from raw[0]
        // if mask[0] had bit 7 set (see "Bit-7 asymmetry" note above; intentional).
        let newHeader = Data([unmasked[0] & 0x7f, unmasked[1]])

        // Re-assemble without the IFAC region (Transport.py:1467).
        let newRaw = newHeader + unmasked.dropFirst(2 + size)

        // Re-sign and compare (Transport.py:1470).
        let expectedIfac = Data(DeterministicSigner.sign(message: newRaw, seed: seed).suffix(size))

        // Constant-time comparison — the reference uses plain ==, but we deliberately
        // improve on it (as Lower-Sideband also does) to avoid timing side-channels.
        guard constantTimeEqual(ifac, expectedIfac) else { return nil }

        return newRaw
    }

    // MARK: — Equatable

    public static func == (lhs: IFAC, rhs: IFAC) -> Bool {
        lhs.key == rhs.key && lhs.size == rhs.size
    }

    // MARK: — Private storage

    /// The full 64-byte derived key (used as HKDF salt for masking).
    private let key: Data
    /// The Ed25519 signing seed — the LAST 32 bytes of `key`.
    private let seed: Data
    /// Number of bytes of the access code carried on the wire.
    private let size: Int
}

// MARK: — Helpers

/// XOR-reduce over paired bytes, checking all are zero — O(n), branchless on the value.
private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
