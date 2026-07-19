import Testing
import Foundation
@testable import ReTiCA

@Test func flagsByteEncodesAllSubfields() {
    // header2(1)<<6 | cf(1)<<5 | transport(1)<<4 | plain(2)<<2 | announce(1)
    let p = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                   destinationType: .plain, context: .none, contextFlag: true, hops: 0,
                   destinationHash: Data(repeating: 0xAA, count: 16),
                   transportId: Data(repeating: 0xBB, count: 16), payload: Data())
    #expect(p.flags == 0b0111_1001) // 0x79
}

@Test func header1PackUnpackRoundTrips() throws {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .single, context: .none, contextFlag: false, hops: 3,
                   destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
                   payload: Data("hello".utf8))
    let raw = try p.packed()
    // flags: single(0)<<2 | data(0) = 0
    #expect(raw.first == 0x00)
    #expect(raw.count == 2 + 16 + 1 + 5)
    let parsed = try #require(Packet(raw: raw))
    #expect(parsed == p)
}

@Test func header2PackUnpackRoundTripsWithTransportId() throws {
    let p = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                   destinationType: .single, context: .resource, contextFlag: false, hops: 7,
                   destinationHash: Data(repeating: 0x22, count: 16),
                   transportId: Data(repeating: 0x33, count: 16), payload: Data("x".utf8))
    let raw = try p.packed()
    #expect(raw.count == 2 + 16 + 16 + 1 + 1)
    let parsed = try #require(Packet(raw: raw))
    #expect(parsed == p)
    #expect(parsed.transportId == Data(repeating: 0x33, count: 16))
}

@Test func packedRejectsOverMTU() {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                   destinationHash: Data(repeating: 0x00, count: 16), transportId: nil,
                   payload: Data(repeating: 0x00, count: 500))
    #expect(throws: PacketError.exceedsMTU) { _ = try p.packed() }
}

@Test func header2WithoutTransportIdThrows() {
    let p = Packet(headerType: .header2, packetType: .data, transportType: .broadcast,
                   destinationType: .single, context: .none, contextFlag: false, hops: 0,
                   destinationHash: Data(repeating: 0x00, count: 16), transportId: nil,
                   payload: Data())
    #expect(throws: PacketError.missingTransportId) { _ = try p.packed() }
}

@Test func unpackRejectsExcessiveHops() {
    var raw = Data([0x00, 200]) // hops 200 >= 128
    raw.append(Data(repeating: 0, count: 16 + 1))
    #expect(Packet(raw: raw) == nil)
}

@Test func unpackRejectsTruncated() {
    #expect(Packet(raw: Data([0x00, 0x00])) == nil) // no room for dest hash + context
}

@Test func dataComposerEncryptsAndFrames() throws {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: id, groupKey: nil)!
    let plaintext = Data("composed".utf8)
    let packet = Packet.data(to: dest, plaintext: plaintext)
    #expect(packet.packetType == .data)
    #expect(packet.destinationType == .single)
    #expect(packet.destinationHash == dest.hash)
    #expect(packet.headerType == .header1)
    // payload is ciphertext, not plaintext
    #expect(packet.payload != plaintext)
    #expect(dest.decrypt(packet.payload) == plaintext)
    _ = try packet.packed() // frames within MTU
}

@Test func announceComposerSetsTypeAndRatchetFlag() {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: [],
                           identity: id, groupKey: nil)!
    let payload = Data("announce-bytes".utf8)
    let plain = Packet.announce(from: dest, payload: payload)
    #expect(plain.packetType == .announce)
    #expect(plain.context == .none)
    #expect(plain.contextFlag == false)
    #expect(plain.payload == payload)

    let withRatchet = Packet.announce(from: dest, payload: payload,
                                      pathResponse: true, ratchetPresent: true)
    #expect(withRatchet.context == .pathResponse)
    #expect(withRatchet.contextFlag == true)
}
