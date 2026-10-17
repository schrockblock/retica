import Foundation
import ComposableArchitecture
import MeshtasticKit
import ReTiCAInterfaces

extension MeshtasticDriver {
    /// landandair's `RETICULUM_TUNNEL_APP` (Meshtastic_Interface.py:65; MeshProto portnums.pb.swift:233).
    public static let reticulumTunnelPort: UInt32 = 76

    /// Contract 2's live value over ONE `MeshtasticSession`. `start` subscribes to the session's
    /// events, then connects to `config.radio` (retrieve-only — the session never scans); `send`
    /// writes one frame on port 76 to broadcast with the config's channel and hop limit, wantAck
    /// false; `stop` disconnects and always returns. Reconnecting is MeshtasticKit's: the
    /// interface just sees repeated `.connected` / `.disconnected`. The session outlives every
    /// start/stop; its owner must `disconnect()` it before dropping it (its reconnect loop retains it).
    public static func live(session: MeshtasticSession) -> MeshtasticDriver {
        let adapter = MeshtasticLiveAdapter(session: session)
        return MeshtasticDriver(start: { adapter.start($0) },
                                send: { await adapter.send($0) },
                                stop: { await adapter.stop() })
    }

    /// Session end reasons that follow an `.adapterUnavailable` event (MeshtasticKit
    /// `waitForPoweredOn`), so they stay plain drops.
    static let adapterEndReasons: Set<String> = ["unauthorized", "unsupported"]

    /// The pure event mapping. `ownNode` is the radio's node number once configured (nil before):
    /// packets it sent itself (our own rebroadcasts) are dropped. Maps `.packet`, never `.frame`.
    static func driverEvent(for event: MeshtasticEvent, ownNode: UInt32?) -> MeshtasticDriverEvent? {
        switch event {
        case let .configured(myNodeNum, modemPreset):
            return .connected(myNodeNum: myNodeNum, modemPreset: modemPreset)
        case let .packet(from, _, _, portnum, payload, _):
            guard portnum == reticulumTunnelPort, from != ownNode else { return nil }
            return .fragment(from: from, payload)
        case .connection(.reconnecting):
            return .disconnected(reason: nil)
        case let .connection(.disconnected(reason)):
            // A terminal end that is not an adapter cause ("radio not found") would otherwise be
            // invisible: the interface reports no delegate for a drop of a never-online radio.
            if let reason, !adapterEndReasons.contains(reason) { return .unavailable(.other(reason)) }
            return .disconnected(reason: reason)
        case .connection(.connecting), .connection(.configuring), .connection(.connected):
            return nil
        case let .adapterUnavailable(cause):
            return .unavailable(bleCause(cause))
        case .routing, .frame:
            return nil
        }
    }

    static func bleCause(_ cause: MeshtasticAdapterUnavailable) -> BLEAdapterUnavailable {
        switch cause {
        case .poweredOff:          return .poweredOff
        case .unauthorized:        return .unauthorized
        case .unsupported:         return .unsupported
        case let .other(detail):   return .other(detail)
        }
    }
}

/// The state behind `MeshtasticDriver.live(session:)`.
final class MeshtasticLiveAdapter: Sendable {
    let session: MeshtasticSession
    /// The current start's config, read by `send` (Contract 2's `send` takes only the frame).
    private let config = LockIsolated<MeshtasticDriverConfig?>(nil)
    /// `connect(radio:)` calls launched by `start` that have not returned yet.
    private let pendingConnects = LockIsolated(0)

    init(session: MeshtasticSession) {
        self.session = session
    }

    func start(_ newConfig: MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent> {
        config.setValue(newConfig)
        // Subscribe BEFORE connecting: MeshtasticKit registers a subscriber synchronously, so this
        // stream sees every event of the connect below (the current state is replayed first).
        let events = session.events()
        let session = self.session
        let pendingConnects = self.pendingConnects
        pendingConnects.withValue { $0 += 1 }
        // CoreBluetooth connects never time out: connect from a task (Contract 1).
        Task {
            await session.connect(radio: newConfig.radio)
            pendingConnects.withValue { $0 -= 1 }
        }
        return AsyncStream { continuation in
            let pump = Task {
                var ownNode: UInt32?
                for await event in events {
                    if case let .configured(myNodeNum, _) = event { ownNode = myNodeNum }
                    if let mapped = MeshtasticDriver.driverEvent(for: event, ownNode: ownNode) {
                        continuation.yield(mapped)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func send(_ frame: Data) async -> Bool {
        guard let config = config.value else { return false }
        do {
            _ = try await session.send(MeshtasticOutbound(portnum: MeshtasticDriver.reticulumTunnelPort,
                                                         payload: frame, channel: config.channel,
                                                         wantAck: false, hopLimit: config.hopLimit))
            return true
        } catch {
            return false
        }
    }

    /// Always returns (Contract 3). A connect launched by `start` is an unstructured hop onto the
    /// session actor and may reach it AFTER this disconnect — it would then bring the radio up with
    /// nobody listening. A connect returns promptly once a later disconnect supersedes it, so
    /// disconnect again until none is outstanding.
    func stop() async {
        config.setValue(nil)
        await session.disconnect()
        while pendingConnects.value > 0 {
            await Task.yield()
            await session.disconnect()
        }
    }
}
