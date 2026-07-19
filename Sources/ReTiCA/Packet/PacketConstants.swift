import Foundation

/// Packet type (2 low bits of the flags byte).
public enum PacketType: UInt8, Equatable { case data = 0, announce = 1, linkRequest = 2, proof = 3 }

/// Header type (bit 6 of the flags byte).
public enum HeaderType: UInt8, Equatable { case header1 = 0, header2 = 1 }

/// Transport type (bit 4 of the flags byte).
public enum TransportType: UInt8, Equatable { case broadcast = 0, transport = 1 }

/// Destination type (bits 2-3 of the flags byte).
public enum DestinationType: UInt8, Equatable { case single = 0, group = 1, plain = 2, link = 3 }

/// Packet context byte (full reference set from RNS/Packet.py).
public enum PacketContext: UInt8, Equatable {
    case none = 0x00
    case resource = 0x01
    case resourceAdvertisement = 0x02
    case resourceRequest = 0x03
    case resourceHashmapUpdate = 0x04
    case resourceProof = 0x05
    case resourceInitiatorCancel = 0x06
    case resourceReceiverCancel = 0x07
    case cacheRequest = 0x08
    case request = 0x09
    case response = 0x0A
    case pathResponse = 0x0B
    case command = 0x0C
    case commandStatus = 0x0D
    case channel = 0x0E
    case keepalive = 0xFA
    case linkIdentify = 0xFB
    case linkClose = 0xFC
    case linkProof = 0xFD
    case linkRequestRTT = 0xFE
    case linkRequestProof = 0xFF
}
