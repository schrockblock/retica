import Testing
import Foundation
@testable import ReTiCA

private func base() -> Packet {
    Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
           destinationType: .single, context: .none, contextFlag: false, hops: 0,
           destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
           payload: Data("payload".utf8))
}

@Test func hashablePartMatchesReferenceShape() {
    let p = base()
    var expected = Data([p.flags & 0x0F])
    expected.append(p.destinationHash)
    expected.append(p.context.rawValue)
    expected.append(p.payload)
    #expect(p.hashablePart == expected)
    #expect(p.packetHash == Crypto.fullHash(expected))
    #expect(p.truncatedHash.count == 16)
}

@Test func packetHashIsStableAcrossHopsHeaderAndTransportId() {
    var a = base()
    var b = base()
    b.hops = 42
    b.headerType = .header2
    b.transportId = Data(repeating: 0x99, count: 16)
    b.transportType = .transport
    b.contextFlag = true
    #expect(a.packetHash == b.packetHash)
    // changing destination hash / context / payload DOES change the hash
    a.destinationHash = Data(repeating: 0x77, count: 16)
    #expect(a.packetHash != b.packetHash)
}
