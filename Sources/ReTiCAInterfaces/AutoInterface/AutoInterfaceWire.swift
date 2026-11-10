import Foundation
import ReTiCA
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Pure wire functions and constants of AutoInterface (spec 2026-11-10-autointerface §2, §4.1-4.3).
///
/// Reference: RNS 1.6.0 `Interfaces/AutoInterface.py` (`AI`).
public enum AutoInterfaceWire {
    // MARK: Constants (spec §2)

    /// `HW_MTU` (`AI:44`).
    public static let hwMTU = 1196
    /// `DEFAULT_DISCOVERY_PORT` (`AI:47`).
    public static let defaultDiscoveryPort: UInt16 = 29716
    /// `DEFAULT_DATA_PORT` (`AI:48`).
    public static let defaultDataPort: UInt16 = 42671
    /// `DEFAULT_GROUP_ID` (`AI:49`).
    public static let defaultGroupID = Data("reticulum".utf8)
    /// `DEFAULT_IFAC_SIZE` (`AI:50`).
    public static let defaultIFACSize = 16
    /// `PEERING_TIMEOUT` seconds (`AI:61`).
    public static let peeringTimeout: Double = 22.0
    /// `ANNOUNCE_INTERVAL` seconds (`AI:62`).
    public static let announceInterval: Double = 1.6
    /// `PEER_JOB_INTERVAL` seconds (`AI:63`).
    public static let peerJobInterval: Double = 4.0
    /// `MCAST_ECHO_TIMEOUT` seconds (`AI:64`).
    public static let multicastEchoTimeout: Double = 6.5
    /// Reverse peering interval, `1.6 * 3.25` = 5.2 s (`AI:147`).
    public static let reversePeeringInterval: Double = 5.2
    /// Initial peering wait, `1.6 * 1.2` = 1.92 s (`AI:332`).
    public static let initialPeeringWait: Double = 1.92
    /// `BITRATE_GUESS` (`AI:70`).
    public static let bitrateGuess = 10_000_000
    /// `MULTI_IF_DEQUE_LEN` (`AI:72`).
    public static let multiIfDequeLen = 48
    /// `MULTI_IF_DEQUE_TTL` seconds (`AI:73`).
    public static let multiIfDequeTTL: Double = 0.75
    /// `ALL_IGNORE_IFS` (`AI:66`).
    public static let allIgnoreIfs = ["lo0"]
    /// `DARWIN_IGNORE_IFS` (`AI:67`).
    public static let darwinIgnoreIfs = ["awdl0", "llw0", "lo0", "en5"]
    /// Discovery `recvfrom` size (`AI:367`).
    public static let discoveryRecvSize = 1024
    /// Data `recvfrom` size (`socketserver.UDPServer.max_packet_size`, spec §2).
    public static let dataRecvSize = 8192

    // MARK: Group address (spec §4.1)

    /// The 16-byte IPv6 multicast group address. Built directly from the bytes, never via the text
    /// form (spec R10, which overflows `UInt8` when ported literally).
    ///
    /// `g = SHA-256(groupID)`. `group[0] = 0xff`, `group[1] = (type << 4) | scope`, `group[2..3] = 0`,
    /// `group[4..15] = g[2..13]`. Equals the text form built at `AI:203-213`.
    public static func groupAddress(
        groupID: Data, scope: AutoInterfaceConfig.Scope, type: AutoInterfaceConfig.AddressType
    ) -> [UInt8] {
        let g = [UInt8](Crypto.fullHash(groupID))
        var out = [UInt8](repeating: 0, count: 16)
        out[0] = 0xff
        out[1] = (type.nibble << 4) | scope.nibble
        for i in 0..<12 { out[4 + i] = g[2 + i] }
        return out
    }

    // MARK: Discovery token (spec §4.2)

    /// `SHA-256(groupID || utf8(linkLocal))` (`AI:493`, `AI:507`). `linkLocal` must already be
    /// descoped. 32 bytes.
    public static func discoveryToken(groupID: Data, linkLocal: String) -> Data {
        Crypto.fullHash(groupID + Data(linkLocal.utf8))
    }

    // MARK: Address text (spec §4.3)

    /// `descope_linklocal` (`AI:80-85`): `split("%")[0]`, then
    /// `re.sub(r"fe80:[0-9a-f]*::", "fe80::", s)`. The quirk that `fe80:4:0:0:a::` stays unchanged
    /// is reproduced exactly, the regex only matches a `::` directly after one group.
    public static func descope(_ address: String) -> String {
        let base = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? address
        return base.replacingOccurrences(
            of: "fe80:[0-9a-f]*::", with: "fe80::", options: .regularExpression)
    }

    /// `inet_ntop(AF_INET6, bytes)` text, with no scope. Matches Python `ipaddress` for
    /// `fe80::/10` (spec §4.3.5). Returns the empty string unless given exactly 16 bytes.
    public static func formatIPv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok, let end = buffer.firstIndex(of: 0) else { return "" }
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
