import Testing
import Foundation
@testable import ReTiCA

@Test func swiftUnpacksReferencePlainPacket() throws {
    let f = try VectorFixtures.load()
    let raw = Data(hexString: f.plainPacketRaw)!
    let packet = try #require(Packet(raw: raw))
    #expect(packet.packetType == .data)
    #expect(packet.destinationType == .plain)
    #expect(packet.headerType == .header1)
    #expect(packet.destinationHash == Data(hexString: f.plainDestHash))
    #expect(packet.payload == Data(hexString: f.plainPacketPlaintext))
}

@Test func swiftPacksToReferencePlainPacketBytes() throws {
    let f = try VectorFixtures.load()
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(hexString: f.plainDestHash)!, transportId: nil,
                        payload: Data(hexString: f.plainPacketPlaintext)!)
    #expect(try packet.packed() == Data(hexString: f.plainPacketRaw))
}

@Test func swiftPacketHashMatchesReference() throws {
    let f = try VectorFixtures.load()
    let packet = try #require(Packet(raw: Data(hexString: f.plainPacketRaw)!))
    #expect(packet.packetHash == Data(hexString: f.plainPacketHash))
}

@Test func swiftDestinationHashMatchesReferenceSingle() throws {
    let f = try VectorFixtures.load()
    let id = Identity(publicKey: Data(hexString: f.identityPublicKey)!)!
    let hash = Destination.hash(identityHash: id.hash, appName: f.singleAppName,
                                aspects: [f.singleAspect])
    #expect(hash == Data(hexString: f.singleDestHash))
}

@Test func swiftDestinationHashMatchesReferencePlain() throws {
    let f = try VectorFixtures.load()
    let hash = Destination.hash(identityHash: nil, appName: f.plainAppName, aspects: [f.plainAspect])
    #expect(hash == Data(hexString: f.plainDestHash))
}

@Test func swiftValidatesReferenceAnnounce() throws {
    let f = try VectorFixtures.load()
    let parsed = Announce.parse(payload: Data(hexString: f.announcePayload)!,
                                destinationHash: Data(hexString: f.announceDestHash)!,
                                contextFlagSet: f.announceContextFlag)
    let unwrapped = try #require(parsed)
    #expect(unwrapped.publicKey == Data(hexString: f.identityPublicKey))
    #expect(unwrapped.nameHash == Destination.nameHash(appName: f.announceAppName,
                                                       aspects: [f.announceAspect]))
}

@Test func swiftGroupDestinationDecryptsReferenceToken() throws {
    let f = try VectorFixtures.load()
    let dest = Destination(kind: .group, direction: .in, appName: "g", aspects: [],
                           identity: nil, groupKey: Data(hexString: f.tokenKey)!)!
    #expect(dest.decrypt(Data(hexString: f.tokenCiphertext)!) == Data(hexString: f.tokenPlaintext))
}
