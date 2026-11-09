import Testing
import Foundation
@testable import ReTiCATransport

/// A ring holds private keys, so no printing path may show them: `String(describing:)`,
/// `debugDescription`, `String(reflecting:)` and a `Mirror` walk (what `dump` and `customDump` use)
/// each carry no key hex and no key bytes, and say the ring is redacted.
@Test func ownRatchetsNeverPrintKeyBytes() {
    let keys = [Data((0..<32).map { UInt8(0xA0 &+ $0) }), Data((0..<32).map { UInt8(0x30 &+ $0) })]
    let own = Transport.State.OwnRatchets(ring: keys)

    func mirrorText(_ value: Any) -> String {
        var out = ""
        dump(value, to: &out)
        return out
    }
    var walked = ""
    for child in Mirror(reflecting: own).children { walked += "\(child.label ?? "") \(child.value)\n" }

    for printed in [String(describing: own), own.debugDescription, String(reflecting: own),
                    mirrorText(own), walked] {
        let lowered = printed.lowercased()
        for key in keys {
            // Booleans only, so a failure never carries the printed text.
            let leaksHex = lowered.contains(key.map { String(format: "%02x", $0) }.joined())
            let leaksDecimal = printed.contains(key.map { String($0) }.joined(separator: ", "))
            #expect(!leaksHex, "a printing path shows a ratchet key as hex")
            #expect(!leaksDecimal, "a printing path shows a ratchet key's bytes")
        }
        #expect(printed.contains("redacted"), "a printing path does not say the ring is redacted")
        #expect(printed.contains("2 keys"))
    }
}
