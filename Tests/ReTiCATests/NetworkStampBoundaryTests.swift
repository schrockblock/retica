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
