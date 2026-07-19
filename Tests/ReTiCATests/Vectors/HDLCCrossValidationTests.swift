import Testing
import Foundation
@testable import ReTiCA

@Test func swiftHDLCFrameMatchesReference() throws {
    let f = try VectorFixtures.load()
    #expect(HDLC.frame(Data(hexString: f.plainPacketRaw)!) == Data(hexString: f.hdlcFramed))
}

@Test func swiftHDLCDeframeRecoversReferencePacket() throws {
    let f = try VectorFixtures.load()
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(Data(hexString: f.hdlcFramed)!) == [Data(hexString: f.plainPacketRaw)!])
}

@Test func swiftHDLCEscapingMatchesReference() throws {
    let f = try VectorFixtures.load()
    #expect(HDLC.frame(Data(hexString: f.escapeInput)!) == Data(hexString: f.escapeFramed))
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(Data(hexString: f.escapeFramed)!) == [Data(hexString: f.escapeInput)!])
}
