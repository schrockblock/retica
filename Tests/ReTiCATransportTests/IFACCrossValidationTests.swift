import Testing
import Foundation
@testable import ReTiCA
@testable import ReTiCATransport

/// Cross-validation fixture: values produced by genuine reference RNS code paths.
///
/// Fixture script: /tmp/ReTiCA/ifac_fixture.py — it CALLS `RNS.Identity.full_hash`,
/// `RNS.Cryptography.hkdf`, `RNS.Identity.from_bytes` and, crucially, the real
/// `RNS.Transport.transmit()` against a stub interface that captures `process_outgoing`.
/// The masking loop is not reimplemented in the fixture, so the expectations here cannot
/// drift into being circular.
///
/// Reference output (conda env "rns", `python /tmp/ReTiCA/ifac_fixture.py`), RNS 1.4.2:
///   rns_version=1.4.2
///   ifac_key_hex=1c5c27f6fc0d316eb5376fa9a2a95499fd27d475aa6a6beedbbd7324ced99ab597a4dd52d698a0195e8669ef49401092c476453a1edf5168d7024af419ed9eb9
///   wire_hex=980846f1ec10f55cd3faf71fec155c8f29091f10b2c6aae03108812ed6346474d78cfaf5930783258cc74cd4d34eda2801a6cc070249b10c060b24130e6cedd3
///   alpha_beta_key_hex=de1a4ec088f4e582a1cc4f8f6e548a40fa31135cb74965cd5d24040f0442f78a57349958e020ef8968188b33e3ff874e4cb1106a8c1306687bddb31c99870518
///   alpha_beta_swapped_hex=50ec470cf1bf3c4510dd4ab6c24871e7c8071447f1496e2c70d2cf81db5987d0f2d0e4307818873ff1fe9deee93c56f06a8fb18d35c1604ca4f8ff3616caf445
///   order_matters=True
///   alpha_beta_wire_hex=cd26910789fd9ed9bc12bcd9a958fd96f702b43cde7ace9398667b613727e690cd64eb8d54998eae09d912aec3de6116
@Suite("IFAC cross-validation against reference RNS")
struct IFACCrossValidationTests {

    // Fixture values — produced by /tmp/ReTiCA/ifac_fixture.py against real RNS.
    let referenceKeyHex  = "1c5c27f6fc0d316eb5376fa9a2a95499fd27d475aa6a6beedbbd7324ced99ab597a4dd52d698a0195e8669ef49401092c476453a1edf5168d7024af419ed9eb9"
    let referenceWireHex = "980846f1ec10f55cd3faf71fec155c8f29091f10b2c6aae03108812ed6346474d78cfaf5930783258cc74cd4d34eda2801a6cc070249b10c060b24130e6cedd3"

    // Dual-credential fixtures, pinning the ORDER of full_hash(netname) ‖ full_hash(netkey).
    let alphaBetaKeyHex     = "de1a4ec088f4e582a1cc4f8f6e548a40fa31135cb74965cd5d24040f0442f78a57349958e020ef8968188b33e3ff874e4cb1106a8c1306687bddb31c99870518"
    let alphaBetaSwappedHex = "50ec470cf1bf3c4510dd4ab6c24871e7c8071447f1496e2c70d2cf81db5987d0f2d0e4307818873ff1fe9deee93c56f06a8fb18d35c1604ca4f8ff3616caf445"
    let alphaBetaWireHex    = "cd26910789fd9ed9bc12bcd9a958fd96f702b43cde7ace9398667b613727e690cd64eb8d54998eae09d912aec3de6116"

    // The fixed input packet: 0x00, 0x00, then bytes 0..45 (48 bytes total).
    let rawPacket: Data = {
        var d = Data([0x00, 0x00])
        d.append(contentsOf: (0..<46).map { UInt8($0) })
        return d
    }()

    // The dual-credential input packet: 0x00, 0x00, then bytes 0..29 (32 bytes total).
    let alphaBetaPacket: Data = {
        var d = Data([0x00, 0x00])
        d.append(contentsOf: (0..<30).map { UInt8($0) })
        return d
    }()

    let ifac = IFAC(networkName: "retica-xval", passphrase: nil, size: 16)!

    /// Our derived 64-byte key must exactly match the reference ifac_key.
    @Test func derivedKeyMatchesReference() {
        let referenceKey = Data(hexString: referenceKeyHex)!
        // Reconstruct our key via the same derivation path.
        let origin = Crypto.fullHash(Data("retica-xval".utf8))
        let originHash = Crypto.fullHash(origin)
        let ourKey = Crypto.hkdf(length: 64, derivedFrom: originHash, salt: IFAC.salt, context: nil)
        #expect(ourKey == referenceKey)
    }

    /// Our protect(raw) must produce exactly the reference wire bytes.
    /// IFAC codes are byte-reproducible (deterministic signing), making byte-exact comparison valid.
    @Test func protectMatchesReferenceWireBytes() {
        let referenceWire = Data(hexString: referenceWireHex)!
        let ourWire = ifac.protect(rawPacket)
        #expect(ourWire == referenceWire)
    }

    /// unprotect of the reference wire bytes must recover the original packet.
    @Test func unprotectReferenceWireRecoverPacket() {
        let referenceWire = Data(hexString: referenceWireHex)!
        let recovered = ifac.unprotect(referenceWire)
        #expect(recovered == rawPacket)
    }

    /// With BOTH credentials supplied, `ifac_origin` is full_hash(netname) ‖ full_hash(netkey)
    /// — in that ORDER (Reticulum.py:961-966). Nothing else in the suite constrains it: the
    /// inequality tests only assert difference, and the other fixtures are netname-only. An
    /// order-swapped implementation would pass every one of them while being unable to talk to
    /// any real dual-credential network — the same wrong-but-symmetric class the whole
    /// cross-validation exists to catch, on a different axis.
    ///
    /// This asserts on the WIRE rather than a test-side recomputation of hkdf, so it runs
    /// through IFAC's own derivation end-to-end.
    @Test func dualCredentialDerivationMatchesReferenceOrder() {
        let both = IFAC(networkName: "alpha", passphrase: "beta", size: 16)!
        let referenceWire = Data(hexString: alphaBetaWireHex)!
        #expect(both.protect(alphaBetaPacket) == referenceWire)
        #expect(both.unprotect(referenceWire) == alphaBetaPacket)
    }

    /// The order-validation fixture only has teeth if the swapped derivation actually differs.
    /// Reference reports order_matters=True; pin both values so a future edit cannot quietly
    /// make the assertion above vacuous.
    @Test func swappedOrderDerivesADifferentKey() {
        let expected = Data(hexString: alphaBetaKeyHex)!
        let swapped  = Data(hexString: alphaBetaSwappedHex)!
        #expect(expected != swapped)

        // Our derivation must land on the reference-order key, not the swapped one.
        let nameHash = Crypto.fullHash(Data("alpha".utf8))
        let passHash = Crypto.fullHash(Data("beta".utf8))
        let ourKey = Crypto.hkdf(length: 64,
                                 derivedFrom: Crypto.fullHash(nameHash + passHash),
                                 salt: IFAC.salt, context: nil)
        #expect(ourKey == expected)
        #expect(ourKey != swapped)
    }
}

// MARK: — Hex-decode helper

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
