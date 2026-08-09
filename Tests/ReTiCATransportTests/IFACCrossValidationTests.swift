import Testing
import Foundation
@testable import ReTiCA
@testable import ReTiCATransport

/// Cross-validation fixture: values produced by genuine reference RNS code paths.
///
/// Fixture script: /tmp/ReTiCA/ifac_fixture.py
/// Interface config: ifac_netname="retica-xval", no passphrase, ifac_size=16.
/// Input packet: 0x00, 0x00, then bytes 0x00..0x2d (48 bytes total).
///
/// Reference output (conda env "rns", python /tmp/ReTiCA/ifac_fixture.py):
///   ifac_key_hex=1c5c27f6fc0d316eb5376fa9a2a95499fd27d475aa6a6beedbbd7324ced99ab597a4dd52d698a0195e8669ef49401092c476453a1edf5168d7024af419ed9eb9
///   ifac_hex=46f1ec10f55cd3faf71fec155c8f2909
///   wire_hex=980846f1ec10f55cd3faf71fec155c8f29091f10b2c6aae03108812ed6346474d78cfaf5930783258cc74cd4d34eda2801a6cc070249b10c060b24130e6cedd3
@Suite("IFAC cross-validation against reference RNS")
struct IFACCrossValidationTests {

    // Fixture values — produced by /tmp/ReTiCA/ifac_fixture.py against real RNS.
    let referenceKeyHex  = "1c5c27f6fc0d316eb5376fa9a2a95499fd27d475aa6a6beedbbd7324ced99ab597a4dd52d698a0195e8669ef49401092c476453a1edf5168d7024af419ed9eb9"
    let referenceWireHex = "980846f1ec10f55cd3faf71fec155c8f29091f10b2c6aae03108812ed6346474d78cfaf5930783258cc74cd4d34eda2801a6cc070249b10c060b24130e6cedd3"

    // The fixed input packet: 0x00, 0x00, then bytes 0..45 (48 bytes total).
    let rawPacket: Data = {
        var d = Data([0x00, 0x00])
        d.append(contentsOf: (0..<46).map { UInt8($0) })
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
