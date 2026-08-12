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

// MARK: - Ingress size ceiling

/// `Packet.init?(raw:)` must reject any input that exceeds `Packet.mtu` (500 bytes).
/// Reference RNS bounds this at the interface layer (`TCPInterface.check_frame_len`), not in
/// `Packet.unpack`; the ReTiCA bound here is defence in depth — it prevents feeding oversized
/// payloads to every downstream decoder even when delivered via a path that bypasses the HDLC
/// deframer (BLE, L2CAP, link-layer data handlers).
///
/// The maximum legitimate packet is a HEADER_2 packed at exactly `Packet.mtu` (500 bytes):
/// flags(1) + hops(1) + transport_id(16) + dest_hash(16) + context(1) + payload(465) = 500.
/// IFAC is stripped upstream in `Transport.received` before `Packet.init?(raw:)` sees bytes,
/// so the post-strip bound is `Packet.mtu` on all interfaces.
///
/// NOTE: this bound assumes `Packet.mtu = 500`. If MTU negotiation ever lands (`Link.swift:16-21`
/// records the frozen signalling bytes), this guard must be widened to the negotiated value or
/// it will incorrectly drop legitimate packets from peers with a higher negotiated MTU.
@Test func inboundInitRejectsOversized() {
    // Build a technically-parseable but over-MTU raw frame (501 bytes).
    // flags=0x00 (HEADER_1, broadcast, single, data), hops=0.
    var raw = Data([0x00, 0x00])               // flags, hops
    raw.append(Data(repeating: 0x11, count: 16)) // destinationHash
    raw.append(0x00)                             // context = .none
    raw.append(Data(repeating: 0xAA, count: 482)) // payload → total 501 bytes
    #expect(raw.count == 501)
    #expect(Packet(raw: raw) == nil)
}

/// The largest legitimate inbound packet (HEADER_2, 500 bytes total post-IFAC-strip) must parse.
@Test func inboundInitAcceptsLargestLegitimate() {
    // HEADER_2: flags(1) + hops(1) + transport_id(16) + dest_hash(16) + context(1) + payload(465) = 500.
    // flags for HEADER_2 = 0b0100_0000 = 0x40 (headerType2, broadcast, single, data).
    var raw = Data([0x40, 0x00])               // flags (HEADER_2), hops
    raw.append(Data(repeating: 0x22, count: 16)) // transport_id
    raw.append(Data(repeating: 0x33, count: 16)) // destinationHash
    raw.append(0x00)                             // context = .none
    raw.append(Data(repeating: 0xBB, count: 465)) // payload → total 500 bytes
    #expect(raw.count == 500)
    let packet = Packet(raw: raw)
    #expect(packet != nil)
    if let p = packet {
        #expect(p.headerType == .header2)
        #expect(p.transportId == Data(repeating: 0x22, count: 16))
        #expect(p.destinationHash == Data(repeating: 0x33, count: 16))
        #expect(p.payload == Data(repeating: 0xBB, count: 465))
    }
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
