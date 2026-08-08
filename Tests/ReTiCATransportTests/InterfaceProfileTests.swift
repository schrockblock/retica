import Testing
@testable import ReTiCATransport

/// Mode raw values are the RNS wire constants (Interface.py:45-51) so the enum can cross a
/// wire format later without a translation table.
@Test func interfaceModeRawValuesMatchReference() {
    #expect(InterfaceMode.full.rawValue == 0x01)
    #expect(InterfaceMode.pointToPoint.rawValue == 0x02)
    #expect(InterfaceMode.accessPoint.rawValue == 0x03)
    #expect(InterfaceMode.roaming.rawValue == 0x04)
    #expect(InterfaceMode.boundary.rawValue == 0x05)
    #expect(InterfaceMode.gateway.rawValue == 0x06)
    #expect(InterfaceMode.interfaceInternal.rawValue == 0x07)
}

/// Preset values are copied verbatim from reference (TCPInterface.py:76,42 / BLEInterface.py:40,41
/// / Interface.py:104-105). announceCap is the FRACTION 0.02 (Reticulum.py:835), never a percent.
@Test func presetsMatchReferenceDeclaredValues() {
    #expect(InterfaceProfile.tcp.bitrate == 10_000_000)
    #expect(InterfaceProfile.tcp.hwMTU == 262_144)
    #expect(InterfaceProfile.tcp.mode == .full)
    #expect(InterfaceProfile.ble.bitrate == 80_000)
    #expect(InterfaceProfile.ble.hwMTU == 1196)
    #expect(InterfaceProfile.ble.mode == .full)
    #expect(InterfaceProfile.default.bitrate == 62_500)
    #expect(InterfaceProfile.default.hwMTU == nil)
    #expect(InterfaceProfile.default.mode == .full)
    for p in [InterfaceProfile.tcp, .ble, .default] {
        #expect(p.announceCap == 0.02)
    }
}

/// The memberwise init defaults mode to .full and announceCap to 0.02, mirroring how every
/// shipped reference interface declares MODE_FULL and inherits the global cap.
@Test func initDefaultsMatchReferenceConventions() {
    let p = InterfaceProfile(name: "x", bitrate: 1200)
    #expect(p.mode == .full)
    #expect(p.hwMTU == nil)
    #expect(p.announceCap == 0.02)
}
