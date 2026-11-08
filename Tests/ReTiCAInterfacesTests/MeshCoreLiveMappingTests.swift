import Testing
import Foundation
import MeshCoreKit
import ReTiCAInterfaces
@testable import ReTiCAMeshCoreLive

private let mappingKey = Data((0..<32).map { UInt8($0 &+ 0x10) })
private let mappingType: UInt16 = 0xFFFF
private let mappingPayload = Data([0x01, 0x02, 0x03])

private func info() -> MeshCoreRadioInfo {
    MeshCoreRadioInfo(publicKey: mappingKey, name: "Radio", frequencyKHz: 869_525, bandwidthHz: 250_000,
                      spreadingFactor: 11, codingRate: 5, firmwareCode: 11, maxChannels: 8)
}

/// A mapper that has seen its subscription's `.connecting`.
private func live(slot: UInt8? = nil) -> MeshCoreEventMapper {
    var mapper = MeshCoreEventMapper(dataType: mappingType)
    _ = mapper.map(.connection(.connecting))
    if let slot { mapper.slotReady(slot) }
    return mapper
}

private func data(_ index: UInt8, _ type: UInt16 = mappingType) -> MeshCoreEvent {
    .channelData(channelIndex: index, dataType: type, payload: mappingPayload)
}

@Suite struct MeshCoreLiveMappingTests {
    @Test func aReplayedStaleTerminalEndIsDropped() {
        var mapper = MeshCoreEventMapper(dataType: mappingType)
        #expect(mapper.map(.connection(.disconnected(reason: "radio not found"))) == .ignore)
    }

    @Test func eventsAfterConnectingMapNormally() {
        var mapper = MeshCoreEventMapper(dataType: mappingType)
        #expect(mapper.map(.connection(.connecting)) == .ignore)
        #expect(mapper.map(.connection(.reconnecting(attempt: 1))) == .emit(.disconnected(reason: nil)))
    }

    @Test func configuredAsksForThePolicy() {
        var mapper = live()
        #expect(mapper.map(.configured(info())) == .configure(info()))
    }

    @Test func connectedCarriesPrefixKeyAndParams() {
        #expect(MeshCoreEventMapper.connected(info())
                == .connected(selfPrefix: mappingKey.prefix(4), publicKey: mappingKey,
                              params: MeshCoreLinkParams(spreadingFactor: 11, bandwidthHz: 250_000, codingRate: 5)))
    }

    @Test func channelDataFromOurSlotAndTypeIsADatagram() {
        var mapper = live(slot: 2)
        #expect(mapper.map(data(2)) == .emit(.datagram(mappingPayload)))
    }

    @Test func channelDataFromAnotherSlotIsDropped() {
        var mapper = live(slot: 2)
        #expect(mapper.map(data(3)) == .ignore)
    }

    @Test func channelDataOfAnotherTypeIsDropped() {
        var mapper = live(slot: 2)
        #expect(mapper.map(data(2, 0x0001)) == .ignore)
    }

    @Test func channelDataBeforeASlotIsReadyIsDropped() {
        var mapper = live()
        #expect(mapper.map(data(0)) == .ignore)
        #expect(mapper.map(data(2)) == .ignore)
    }

    @Test func rawDataIsADatagramOnceConnected() {
        var mapper = live(slot: 2)
        #expect(mapper.map(.rawData(payload: mappingPayload)) == .emit(.datagram(mappingPayload)))
    }

    @Test func rawDataBeforeASlotIsReadyIsDropped() {
        var mapper = live()
        #expect(mapper.map(.rawData(payload: mappingPayload)) == .ignore)
    }

    @Test func aDropForgetsTheSlot() {
        var mapper = live(slot: 2)
        #expect(mapper.map(.connection(.reconnecting(attempt: 1))) == .emit(.disconnected(reason: nil)))
        #expect(mapper.map(data(2)) == .ignore)
    }

    @Test func aHandshakeForgetsTheSlotUntilThePolicyRuns() {
        var mapper = live(slot: 2)
        _ = mapper.map(.configured(info()))
        #expect(mapper.map(data(2)) == .ignore)
    }

    @Test func reconnectingIsADisconnect() {
        var mapper = live()
        #expect(mapper.map(.connection(.reconnecting(attempt: 3))) == .emit(.disconnected(reason: nil)))
        #expect(mapper.map(.connection(.disconnected(reason: nil))) == .emit(.disconnected(reason: nil)))
    }

    @Test func aTerminalEndIsUnavailableWithItsReason() {
        var mapper = live()
        #expect(mapper.map(.connection(.disconnected(reason: "radio not found")))
                == .emit(.unavailable(.other("radio not found"))))
    }

    @Test(arguments: ["unauthorized", "unsupported"])
    func anAdapterEndIsIgnored(reason: String) {
        var mapper = live()
        #expect(mapper.map(.connection(.disconnected(reason: reason))) == .ignore)
    }

    @Test func tooOldFirmwareEndUsesTheContractMessage() {
        var mapper = live()
        let step = mapper.map(.connection(.disconnected(reason: MeshCoreSession.firmwareTooOldReason)))
        #expect(step == .emit(.unavailable(.other("This radio's firmware is too old; update to v1.15 or later"))))
    }

    @Test(arguments: [
        (MeshCoreAdapterUnavailable.poweredOff, BLEAdapterUnavailable.poweredOff),
        (.unauthorized, .unauthorized),
        (.unsupported, .unsupported),
        (.other("x"), .other("x")),
        (.other(nil), .other(nil)),
    ])
    func adapterCausesMap(cause: MeshCoreAdapterUnavailable, expected: BLEAdapterUnavailable) {
        var mapper = live()
        #expect(mapper.map(.adapterUnavailable(cause)) == .emit(.unavailable(expected)))
    }

    /// Contract 1: map `.frame` OR the typed cases. The typed ones are mapped, so a frame that
    /// decodes to the same data (and the legacy 0x07/0x08 codes) must add nothing.
    @Test func framesAreIgnored() {
        var mapper = live(slot: 2)
        #expect(mapper.map(.frame(.channelDataRecv(channelIndex: 2, dataType: mappingType,
                                                   payload: mappingPayload))) == .ignore)
        #expect(mapper.map(.frame(.rawData(payload: mappingPayload))) == .ignore)
        #expect(mapper.map(.frame(.unknown(code: 0x07))) == .ignore)
        #expect(mapper.map(.frame(.unknown(code: 0x08))) == .ignore)
    }

    @Test func connectionProgressIsIgnored() {
        var mapper = live()
        #expect(mapper.map(.connection(.connecting)) == .ignore)
        #expect(mapper.map(.connection(.configuring)) == .ignore)
        #expect(mapper.map(.connection(.connected)) == .ignore)
    }

    @Test func policyFailureIsExactlyTheThreePolicyMessages() {
        #expect(MeshCoreLiveMessage.isPolicyFailure(MeshCoreLiveMessage.noFreeSlot))
        #expect(MeshCoreLiveMessage.isPolicyFailure(MeshCoreLiveMessage.firmwareTooOld))
        #expect(MeshCoreLiveMessage.isPolicyFailure(MeshCoreLiveMessage.channelSetupFailed))
        #expect(!MeshCoreLiveMessage.isPolicyFailure("radio not found"))
        #expect(!MeshCoreLiveMessage.isPolicyFailure(""))
        #expect(MeshCoreLiveMessage.noFreeSlot == "No free channel slot on this radio")
        #expect(MeshCoreLiveMessage.channelSetupFailed == "Couldn't set up the channel on this radio")
    }
}
