import Testing
import Foundation
@testable import ReTiCA

// The two comparisons in NetworkStamp that random fixtures almost never land on: `hash <= target`
// (equality counts) and the bisect_right table lookup (a mantissa equal to an entry takes that entry).

@Test func hashMeetsAcceptsAHashEqualToTheTarget() {
    for target in [Data(repeating: 0x00, count: 32), Data(repeating: 0x7F, count: 32),
                   Data((0..<32).map { UInt8($0 * 7 + 3) })] {
        #expect(NetworkStamp.hashMeets(target, target: [UInt8](target)))
    }
}

@Test func hashMeetsRejectsAHashOneAboveTheTarget() {
    // target + 1, with carry: ...00 FF becomes ...01 00.
    var target = [UInt8](repeating: 0x12, count: 32)
    target[31] = 0xFF
    var above = target
    above[31] = 0x00
    above[30] = 0x13
    #expect(!NetworkStamp.hashMeets(Data(above), target: target))
    // One below is accepted.
    var below = target
    below[31] = 0xFE
    #expect(NetworkStamp.hashMeets(Data(below), target: target))
    // Difference only in the first byte decides.
    var high = target
    high[0] = 0x13
    #expect(!NetworkStamp.hashMeets(Data(high), target: target))
}

/// A 32-byte hash with `leadingZeros` zero bits and then the 34-bit `mantissa` (its top bit is the
/// leading one), the rest zero.
private func hash(leadingZeros: Int, mantissa: UInt64) -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    for k in 0..<34 where mantissa >> UInt64(33 - k) & 1 == 1 {
        let bit = leadingZeros + k   // counted from the most significant bit
        bytes[bit / 8] |= UInt8(0x80) >> UInt8(bit % 8)
    }
    return Data(bytes)
}

/// `value` end to end at the bisect_right boundary (RNS/Stamps.py stamp_value: the value is
/// `((lz + 1) << 8) - bisect_right(TAB, mantissa)`, over 256). A mantissa EQUAL to `tab[i]` takes entry i,
/// so it is `i + 1` below the ceiling, one more than the mantissa just under it. Computed here from
/// the table index, not through `tabClimb`.
@Test func valueAtABisectRightBoundaryTakesTheEqualEntry() {
    let lz = 10
    let ceiling = (lz + 1) << 8
    for index in [0, 1, 2, 100, 255] {
        let entry = NetworkStamp.tab[index]
        #expect(NetworkStamp.value(hash: hash(leadingZeros: lz, mantissa: entry))
                    == Double(ceiling - (index + 1)) / 256, "entry \(index)")
        // One below: for index 0 no entry is at or below it, otherwise the previous one is.
        #expect(NetworkStamp.value(hash: hash(leadingZeros: lz, mantissa: entry - 1))
                    == Double(ceiling - index) / 256, "entry \(index) - 1")
    }
    // The all-zero hash is the one special case.
    #expect(NetworkStamp.value(hash: Data(repeating: 0, count: 32)) == 256)
}

@Test func tabLookupIsBisectRight() {
    for index in [0, 1, 100, 255] {
        let entry = NetworkStamp.tab[index]
        // Equal to an entry: that entry counts, so the climb is index + 1.
        #expect(NetworkStamp.tabClimb(mantissa: entry) == index + 1, "entry \(index)")
        // One less: the previous entry is the last one at or below.
        #expect(NetworkStamp.tabClimb(mantissa: entry - 1) == index, "entry \(index) - 1")
    }
    // Above the last entry every entry is at or below.
    #expect(NetworkStamp.tabClimb(mantissa: NetworkStamp.tab[255] + 1) == 256)
}
