import Foundation
import ComposableArchitecture
import ReTiCA
#if canImport(Darwin)
import Darwin
#endif

/// The AutoInterface mechanism (spec 2026-11-10-autointerface §5.4): multicast discovery, peer
/// add/refresh/evict, reverse announces, link-local change handling, the echo watchdog and the data
/// plane, over the `AutoInterfaceDriver` sockets.
///
/// Reference: RNS 1.6.0 `Interfaces/AutoInterface.py` (`AI`). The reducer owns no Transport
/// registration: the host registers one interface per `peerAdded` and deregisters on `peersRemoved`
/// and on `.stop` (spec §5.7), the reference parent being a no-op sink (`AI:617`).
///
/// Divergences (spec §5.6, none visible on the wire): D1 an address change rebinds all three
/// sockets; D2 NICs are re-enumerated every peer-job tick; D3 a data-port clash fails only that NIC
/// and is retried every tick; D4 a peer cap.
@Reducer
public struct AutoInterface {
    @ObservableState
    public struct State: Equatable {
        public var config: AutoInterfaceConfig
        /// IFAC size in bytes. Inbound data longer than `HW_MTU + ifacSize` is dropped, the check the
        /// reference makes in Transport (`TP:2017-2018`). The reference sets 16 on every interface
        /// whether or not IFAC is configured (`RT:1130-1131`), so 1212 by default.
        public var ifacSize: Int
        public internal(set) var status: Status = .stopped
        /// Adopted NICs by name.
        public internal(set) var nics: [String: NIC] = [:]
        /// Peers keyed by address only: the first NIC an address is heard on stays its NIC (`AI:540-541`).
        public internal(set) var peers: [String: Peer] = [:]
        /// The reference's `final_init_done`: nothing inbound is accepted until the 1.92 s initial
        /// peering wait has passed (`AI:331-356`, `AI:368`).
        public internal(set) var accepting = false
        /// The parent-wide multi-interface dedupe ring (`AI:136-137`, `AI:652-668`), oldest first.
        var mif: [MIFEntry] = []
        /// Every link-local address of every eligible NIC seen this session. A discovery datagram from
        /// one of them is our own multicast echo and never a peer (`AI:527`). Kept across address
        /// changes, so a late echo of a replaced address is still recognised as ours.
        var ownAddresses: Set<String> = []
        /// NICs whose multicast join failed this session (spec R11): not re-adopted while present.
        var skippedNICs: Set<String> = []
        var sessionStart: Date?
        /// A send failed with an errno that local-network denial produces (spec §8.4).
        var deniedSendSeen = false
        var localNetworkDeniedReported = false
        /// `.stop` launched `driver.stop()` and its `.driverStopped` has not arrived. The driver's
        /// `stop()` ends whatever session is live when it runs, so a `run` must not precede it.
        var stopping = false
        /// A `.start` arrived while `stopping`: `.driverStopped` starts the session.
        var restartPending = false
        /// Bumped at reduce time by every `.stop` that reaches the driver (see `DriverEpoch`).
        var epoch = DriverEpoch()

        /// Stopped with no `driver.stop()` in flight: a host may drop this state now.
        public var isIdle: Bool { status == .stopped && !stopping }

        public init(config: AutoInterfaceConfig = AutoInterfaceConfig(), ifacSize: Int = AutoInterfaceWire.defaultIFACSize) {
            self.config = config
            self.ifacSize = ifacSize
        }
    }

    public enum Status: Equatable, Sendable { case stopped, starting, running, noUsableInterfaces }

    public struct NIC: Equatable, Sendable {
        public var index: UInt32
        /// The adopted, descoped link-local address. Our discovery token hashes it.
        public var linkLocal: String
        /// The reference's `multicast_echoes[nic]`, seeded at adoption (`AI:241`).
        public var lastEcho: Date
        /// The reference's `initial_echoes[nic]` (`AI:535`).
        public var firstEcho: Date?
        /// The reference's `timed_out_interfaces[nic]`: nil until the first watchdog pass (`AI:468-477`).
        public var timedOut: Bool?
        /// Planes whose bind or read failed. Retried with `rebind` every peer-job tick.
        public var failed: Set<AutoPlane> = []
        var multicastUnavailableReported = false
        var dataPortInUseReported = false
        /// All three planes have been bound at least once since adoption. Only a NIC that never got
        /// there is skipped for a failed multicast join (R11); later a failed join is a retryable plane.
        var everBound = false
    }

    public struct Peer: Equatable, Sendable {
        public var nic: String
        public var index: UInt32
        public var lastHeard: Date
        public var lastOutbound: Date
    }

    struct MIFEntry: Equatable, Sendable {
        var hash: Data
        var time: Date
    }

    public enum Action: Equatable, Sendable {
        case start
        case stop
        /// Send one raw (IFAC-masked) packet to a peer: one datagram (`AI:670-677`).
        case send(addr: String, data: Data)
        case announceTick
        case peerJobTick
        case socketEvent(AutoSocketEvent)
        /// The 1.92 s initial peering wait passed (`AI:353-356`). Internal.
        case peeringWaitElapsed
        /// A send failed with a local-network-denial errno (spec §8.4). Internal.
        /// `generation` is the epoch the send was issued in. Internal.
        case sendFailed(errno: Int32, generation: Int)
        /// `driver.stop()` returned: a deferred `.start` may now run. Internal.
        case driverStopped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable, Sendable {
            case peerAdded(addr: String, nic: String)
            /// Every peer that left in one reduction (an eviction tick, vanished NICs, a skipped NIC),
            /// sorted, never empty. One delegate for the lot, so the host sees them leave together:
            /// reported one by one, each of the host's arms would still see the others registered
            /// (TCA runs the queued sends in order), and a "was that the last interface?" check
            /// would never fire.
            case peersRemoved(addrs: [String])
            case packetReceived(addr: String, data: Data)
            case carrierLost(nic: String)
            case carrierRecovered(nic: String)
            /// No multicast echo has ever arrived on this NIC 6.5 s after adoption, or its multicast
            /// join failed. Once per NIC adoption.
            case multicastUnavailable(nic: String)
            /// The data port is taken on this NIC (usually a local rnsd or NomadNet, spec §4.10).
            case dataPortInUse(nic: String)
            case noUsableInterfaces
            /// Denied-class send errors and no echo 6.5 s into the session. Once per session (§8.4).
            case localNetworkDenied
        }
    }

    @Dependency(\.autoInterfaceDriver) var driver
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date

    private enum CancelID: Hashable { case stream, announce, peerJob, peeringWait }

    /// Send errors that local-network denial or a missing multicast entitlement produce (spec §8.4).
    static let deniedErrnos: Set<Int32> = [EHOSTUNREACH, ENETUNREACH, EPERM]

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                guard state.status == .stopped else { return .none }
                state.status = .starting
                if state.stopping {
                    state.restartPending = true
                    return .none
                }
                return startSession(&state)

            case .stop:
                if state.stopping {
                    // The stop in flight covers this one; a start deferred behind it never ran.
                    state.restartPending = false
                    state.status = .stopped
                    return .none
                }
                guard state.status != .stopped else { return .none }
                // At reduce time: a start effect built in this same burst has not registered its
                // cancel ids yet, so the cancels below miss it (see `DriverEpoch`).
                state.epoch.invalidate()
                state.status = .stopped
                state.stopping = true
                state.accepting = false
                state.nics = [:]
                state.peers = [:]
                state.mif = []
                state.ownAddresses = []
                state.skippedNICs = []
                return .merge(cancelSession(), .run { [driver] send in
                    await driver.stop()
                    await send(.driverStopped)
                })

            case .driverStopped:
                state.stopping = false
                guard state.restartPending else { return .none }
                state.restartPending = false
                return startSession(&state)

            case .peeringWaitElapsed:
                guard isLive(state) else { return .none }
                state.accepting = true
                return updateStatus(&state)

            case .announceTick:
                guard isLive(state) else { return .none }
                // `peer_announce` per adopted NIC (`AI:485-513`). A NIC with a failed plane is down
                // until its rebind succeeds (D3).
                let groupID = state.config.groupID
                let port = state.config.discoveryPort
                let sends = state.nics.sorted { $0.key < $1.key }.filter { $0.value.failed.isEmpty }
                    .map { (nic: $0.key, token: AutoInterfaceWire.discoveryToken(groupID: groupID, linkLocal: $0.value.linkLocal)) }
                guard !sends.isEmpty else { return .none }
                let epoch = state.epoch, generation = epoch.current
                return .run { [driver] send in
                    for s in sends {
                        guard epoch.current == generation else { return }
                        await Self.report(await driver.sendMulticast(s.nic, s.token, port), generation, send)
                    }
                }

            case .peerJobTick:
                guard isLive(state) else { return .none }
                return peerJob(&state)

            case let .socketEvent(event):
                guard isLive(state) else { return .none }
                return socketEvent(event, &state)

            case let .send(addr, data):
                guard isLive(state), let peer = state.peers[addr] else { return .none }
                let port = state.config.dataPort
                let epoch = state.epoch, generation = epoch.current
                return .run { [driver] send in
                    guard epoch.current == generation else { return }
                    await Self.report(await driver.sendUnicast(addr, peer.index, port, data), generation, send)
                }

            case let .sendFailed(_, generation):
                // A send of an earlier session (its effect is not cancellable) must not mark this one.
                guard isLive(state), generation == state.epoch.current else { return .none }
                state.deniedSendSeen = true
                return checkLocalNetworkDenied(&state, now: date.now)

            case .delegate:
                return .none
            }
        }
    }

    // MARK: Session

    private func isLive(_ state: State) -> Bool { state.status != .stopped && !state.stopping }

    /// `.start` (spec §5.4.1): enumerate and filter NICs, run the socket session, and start the
    /// announce (at once, then every 1.6 s), peer-job (every 4.0 s) and 1.92 s accept timers.
    private func startSession(_ state: inout State) -> Effect<Action> {
        let now = date.now
        state.sessionStart = now
        state.accepting = false
        state.peers = [:]
        state.mif = []
        state.nics = [:]
        state.ownAddresses = []
        state.skippedNICs = []
        state.deniedSendSeen = false
        state.localNetworkDeniedReported = false
        var bindings: [AutoBinding] = []
        for nic in driver.interfaces() where state.config.isEligible(nicName: nic.name) {
            state.ownAddresses.formUnion(Self.linkLocals(nic))
            guard let ll = Self.adoptedLinkLocal(nic) else { continue }
            state.nics[nic.name] = NIC(index: nic.index, linkLocal: ll, lastEcho: now)
            bindings.append(Self.binding(nic.name, nic.index, ll, state.config))
        }
        // With no usable NIC the session still runs (and the peer-job timer with it), so a NIC
        // that appears later is adopted with `rebind`, which is a no-op outside a session (D2).
        state.status = bindings.isEmpty ? .noUsableInterfaces : .starting

        let epoch = state.epoch
        let generation = epoch.current
        let stream: Effect<Action> = .run { [driver, bindings] send in
            // A `.stop` reduced since this was built (possibly in this burst) wins.
            guard let events = epoch.start(ifCurrent: generation, { driver.run(bindings) }) else { return }
            for await event in events { await send(.socketEvent(event)) }
        }
        .cancellable(id: CancelID.stream, cancelInFlight: true)
        var effects: [Effect<Action>] = [
            stream,
            timer(.announceTick, every: AutoInterfaceWire.announceInterval, immediately: true,
                  epoch: epoch, generation: generation, id: .announce),
            timer(.peerJobTick, every: AutoInterfaceWire.peerJobInterval, immediately: false,
                  epoch: epoch, generation: generation, id: .peerJob),
            .run { [clock] send in
                try await clock.sleep(for: .seconds(AutoInterfaceWire.initialPeeringWait))
                guard epoch.current == generation else { return }
                await send(.peeringWaitElapsed)
            }
            .cancellable(id: CancelID.peeringWait, cancelInFlight: true),
        ]
        if bindings.isEmpty { effects.append(.send(.delegate(.noUsableInterfaces))) }
        return .merge(effects)
    }

    /// A function, never a stored `let`: constructing `.cancel(id:)` cancels at once.
    private func cancelSession() -> Effect<Action> {
        .merge(.cancel(id: CancelID.stream), .cancel(id: CancelID.announce),
               .cancel(id: CancelID.peerJob), .cancel(id: CancelID.peeringWait))
    }

    /// Sends `action` every `interval` seconds (and at once if `immediately`) until cancelled or the
    /// epoch moves on. The epoch check covers a `.stop` reduced before this task registered its id.
    private func timer(_ action: Action, every interval: Double, immediately: Bool,
                       epoch: DriverEpoch, generation: Int, id: CancelID) -> Effect<Action> {
        .run { [clock] send in
            guard epoch.current == generation else { return }
            if immediately { await send(action) }
            while true {
                try await clock.sleep(for: .seconds(interval))
                guard epoch.current == generation else { return }
                await send(action)
            }
        }
        .cancellable(id: id, cancelInFlight: true)
    }

    // MARK: Socket events

    private func socketEvent(_ event: AutoSocketEvent, _ state: inout State) -> Effect<Action> {
        switch event {
        case let .bound(nic):
            guard var entry = state.nics[nic] else { return .none }
            if !entry.failed.isEmpty {
                // Back from a failure: the watchdog skipped this NIC while it was down (it sent no
                // announces, so it could hear no echo). Restart its echo clock as at adoption.
                entry.lastEcho = date.now
                entry.timedOut = nil
            }
            entry.failed = []
            entry.dataPortInUseReported = false
            entry.everBound = true
            state.nics[nic] = entry
            return .none

        case let .bindFailed(nic, .multicastDiscovery, _) where state.nics[nic]?.everBound == false:
            // Spec R11: a NIC that cannot join the group is skipped, as the reference's per-NIC `try`
            // does (`AI:314-319`). The planes that did bind stay open until unbound. Only for a NIC
            // that never bound: a join that fails on a later rebind (an address change, a retry) is a
            // transient failed plane, retried every tick like any other (below).
            guard state.nics[nic] != nil else { return .none }
            var removed: [String] = []
            var effects = [removeNIC(nic, &state, removed: &removed)]
            if let gone = Self.peersRemoved(removed) { effects.append(gone) }
            state.skippedNICs.insert(nic)
            effects.append(.send(.delegate(.multicastUnavailable(nic: nic))))
            effects.append(updateStatus(&state))
            return .merge(effects)

        case let .bindFailed(nic, plane, errno):
            guard var entry = state.nics[nic] else { return .none }
            entry.failed.insert(plane)
            var effects: [Effect<Action>] = []
            // D3: the same-host clash of §4.10 fails only this NIC (the reference panics, `RT:1307-1311`).
            if plane == .data, errno == EADDRINUSE, !entry.dataPortInUseReported {
                entry.dataPortInUseReported = true
                effects.append(.send(.delegate(.dataPortInUse(nic: nic))))
            }
            state.nics[nic] = entry
            return .merge(effects)

        case let .readFailed(nic, plane, _):
            // The driver closed that socket; the next peer-job tick rebinds the NIC.
            state.nics[nic]?.failed.insert(plane)
            return .none

        case let .datagram(_, .data, source, _, payload):
            return dataDatagram(from: AutoInterfaceWire.descope(source), payload, &state)

        case let .datagram(_, _, source, sourceScope, payload):
            return discoveryDatagram(from: AutoInterfaceWire.descope(source), scope: sourceScope, payload, &state)
        }
    }

    /// `discovery_handler` + `add_peer` (`AI:358-374`, `AI:526-607`, spec §4.5-4.6).
    private func discoveryDatagram(from src: String, scope: UInt32, _ payload: Data, _ state: inout State) -> Effect<Action> {
        // Dropped until the initial peering wait has passed (`AI:368`).
        guard state.accepting else { return .none }
        // `data[:32] == SHA-256(group_id || src)`: shorter fails, trailing bytes are ignored (`AI:369-371`).
        let token = AutoInterfaceWire.discoveryToken(groupID: state.config.groupID, linkLocal: src)
        guard payload.count >= token.count, payload.prefix(token.count) == token else { return .none }
        let now = date.now

        // Echo: our own address. It belongs to the NIC whose adopted address it is, whichever NIC
        // it arrived on, and it never creates a peer (`AI:527-537`).
        if state.ownAddresses.contains(src) || state.nics.values.contains(where: { $0.linkLocal == src }) {
            if let name = state.nics.first(where: { $0.value.linkLocal == src })?.key {
                state.nics[name]?.lastEcho = now
                if state.nics[name]?.firstEcho == nil { state.nics[name]?.firstEcho = now }
            }
            return .none
        }

        // Attribute by the source's scope: on non-link scopes every NIC's group socket shares the
        // port, so the arrival socket need not be the arrival NIC. Hardening only.
        guard let arrival = state.nics.first(where: { $0.value.index == scope }),
              arrival.value.failed.isEmpty else { return .none }
        let name = arrival.key, nic = arrival.value

        if state.peers[src] != nil {
            state.peers[src]?.lastHeard = now   // `refresh_peer` (`AI:606-611`)
            return .none
        }
        // D4 (spec R4): the reference has no cap.
        guard state.peers.count < state.config.peerCap else { return .none }
        state.peers[src] = Peer(nic: name, index: nic.index, lastHeard: now, lastOutbound: now)
        return .send(.delegate(.peerAdded(addr: src, nic: name)))
    }

    /// `process_incoming` (`AI:613-615`, `AI:652-668`, spec §4.8).
    private func dataDatagram(from src: String, _ payload: Data, _ state: inout State) -> Effect<Action> {
        // Dispatched by source address only; unknown sources are dropped (`AI:613-615`).
        guard state.accepting, state.peers[src] != nil else { return .none }
        // Transport's MTU check (`TP:2017-2018`), which ReTiCA's Transport does not make. An empty
        // datagram is no packet (ReTiCA addition, no wire effect).
        guard !payload.isEmpty, payload.count <= AutoInterfaceWire.hwMTU + state.ifacSize else { return .none }
        let now = date.now
        let hash = Crypto.fullHash(payload)
        let ttl = AutoInterfaceWire.multiIfDequeTTL
        // A hit (same hash, `now < t + 0.75`) is dropped and does NOT refresh the peer (`AI:656-662`).
        if state.mif.contains(where: { $0.hash == hash && now < $0.time.addingTimeInterval(ttl) }) {
            return .none
        }
        state.peers[src]?.lastHeard = now
        state.mif.append(MIFEntry(hash: hash, time: now))
        if state.mif.count > AutoInterfaceWire.multiIfDequeLen {
            state.mif.removeFirst(state.mif.count - AutoInterfaceWire.multiIfDequeLen)
        }
        return .send(.delegate(.packetReceived(addr: src, data: payload)))
    }

    // MARK: Peer job

    /// `peer_jobs` (`AI:376-482`) in its order: evict, reverse announce, link-local change (here
    /// also D1/D2/D3), echo watchdog.
    private func peerJob(_ state: inout State) -> Effect<Action> {
        let now = date.now
        var effects: [Effect<Action>] = []
        // Every peer this tick removes (evicted here, or with a vanished NIC in step 3), reported
        // in ONE `peersRemoved` (see that case).
        var removed: [String] = []

        // 1. Evict peers not heard for more than 22 s (`AI:383-396`).
        let timedOut = state.peers.filter { now > $0.value.lastHeard.addingTimeInterval(AutoInterfaceWire.peeringTimeout) }
        for addr in timedOut.keys.sorted() {
            state.peers[addr] = nil
            removed.append(addr)
        }

        // 2. Reverse announce: our token for the peer's NIC, to its unicast discovery port
        //    (`AI:399-408`, `AI:490-499`).
        var reverse: [(addr: String, index: UInt32, token: Data)] = []
        for addr in state.peers.keys.sorted() {
            guard let peer = state.peers[addr], let nic = state.nics[peer.nic],
                  now > peer.lastOutbound.addingTimeInterval(AutoInterfaceWire.reversePeeringInterval) else { continue }
            reverse.append((addr, peer.index, AutoInterfaceWire.discoveryToken(groupID: state.config.groupID, linkLocal: nic.linkLocal)))
            state.peers[addr]?.lastOutbound = now
        }
        if !reverse.isEmpty {
            let port = state.config.unicastDiscoveryPort
            let epoch = state.epoch, generation = epoch.current
            effects.append(.run { [driver, reverse] send in
                for r in reverse {
                    guard epoch.current == generation else { return }
                    await Self.report(await driver.sendUnicast(r.addr, r.index, port, r.token), generation, send)
                }
            })
        }

        // 3. Re-enumerate NICs (`AI:410-457`, D1, D2, D3).
        effects.append(reenumerate(&state, now: now, removed: &removed))
        // First, so the host deregisters the departed before it hears anything else from this tick.
        if let gone = Self.peersRemoved(removed) { effects.insert(gone, at: 0) }

        // 4. Echo watchdog (`AI:462-480`): transitions only, the first pass is silent. A NIC with a
        //    failed plane is skipped: it sends no announces (D3), so a missing echo says nothing
        //    about multicast, and reporting it would read as "firewall blocks multicast" next to
        //    the `dataPortInUse` that is the real cause. `.bound` restarts its echo clock.
        for name in state.nics.keys.sorted() {
            guard var nic = state.nics[name], nic.failed.isEmpty else { continue }
            let lost = now.timeIntervalSince(nic.lastEcho) > AutoInterfaceWire.multicastEchoTimeout
            if lost, nic.timedOut == false { effects.append(.send(.delegate(.carrierLost(nic: name)))) }
            if !lost, nic.timedOut == true { effects.append(.send(.delegate(.carrierRecovered(nic: name)))) }
            nic.timedOut = lost
            // The reference logs "No multicast echoes received" every tick (`AI:479-480`); we
            // surface it once, when 6.5 s have passed without any echo.
            if lost, nic.firstEcho == nil, !nic.multicastUnavailableReported {
                nic.multicastUnavailableReported = true
                effects.append(.send(.delegate(.multicastUnavailable(nic: name))))
            }
            state.nics[name] = nic
        }
        effects.append(checkLocalNetworkDenied(&state, now: now))
        return .merge(effects)
    }

    private func reenumerate(_ state: inout State, now: Date, removed: inout [String]) -> Effect<Action> {
        let snapshot = driver.interfaces().filter { state.config.isEligible(nicName: $0.name) }
        let present = Dictionary(snapshot.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var effects: [Effect<Action>] = []

        for name in state.nics.keys.sorted() {
            guard var nic = state.nics[name] else { continue }
            guard let fresh = present[name], let ll = Self.adoptedLinkLocal(fresh) else {
                // D2: a vanished NIC is unbound and its peers evicted at once.
                effects.append(removeNIC(name, &state, removed: &removed))
                continue
            }
            if ll != nic.linkLocal || fresh.index != nic.index {
                // D1: rebind all three sockets (the reference restarts only the data listener,
                // `AI:429-455`). Existing peers keep working until they time out.
                nic.linkLocal = ll
                nic.index = fresh.index
                state.nics[name] = nic
                for addr in state.peers.keys where state.peers[addr]?.nic == name { state.peers[addr]?.index = fresh.index }
                effects.append(rebind(Self.binding(name, fresh.index, ll, state.config), state))
            } else if !nic.failed.isEmpty {
                // D3: retry a NIC with a failed plane every tick.
                effects.append(rebind(Self.binding(name, nic.index, nic.linkLocal, state.config), state))
            }
        }
        // D2: adopt NICs that appeared (or gained a link-local address).
        for fresh in snapshot where state.nics[fresh.name] == nil && !state.skippedNICs.contains(fresh.name) {
            guard let ll = Self.adoptedLinkLocal(fresh) else { continue }
            state.nics[fresh.name] = NIC(index: fresh.index, linkLocal: ll, lastEcho: now)
            effects.append(rebind(Self.binding(fresh.name, fresh.index, ll, state.config), state))
        }
        for nic in snapshot { state.ownAddresses.formUnion(Self.linkLocals(nic)) }
        // A skipped NIC that went away may be adopted again when it returns.
        state.skippedNICs.formIntersection(present.keys)
        effects.append(updateStatus(&state))
        return .merge(effects)
    }

    /// Rebind and unbind effects are not cancellable, so each carries the session's epoch: one left
    /// over from a stopped session must not rebind or tear down a NIC of the next session.
    private func rebind(_ binding: AutoBinding, _ state: State) -> Effect<Action> {
        let epoch = state.epoch, generation = epoch.current
        return .run { [driver] _ in
            guard epoch.current == generation else { return }
            await driver.rebind(binding)
        }
    }

    /// Drops a NIC: evicts its peers (appended to `removed`, for the caller's one `peersRemoved`)
    /// and returns the unbind.
    private func removeNIC(_ name: String, _ state: inout State, removed: inout [String]) -> Effect<Action> {
        state.nics[name] = nil
        for addr in state.peers.keys.sorted() where state.peers[addr]?.nic == name {
            state.peers[addr] = nil
            removed.append(addr)
        }
        let epoch = state.epoch, generation = epoch.current
        return .run { [driver] _ in
            guard epoch.current == generation else { return }
            await driver.unbind(name)
        }
    }

    /// The one delegate for every peer a reduction removed, or nil when it removed none.
    private static func peersRemoved(_ addrs: [String]) -> Effect<Action>? {
        addrs.isEmpty ? nil : .send(.delegate(.peersRemoved(addrs: addrs.sorted())))
    }

    /// Keeps `status` in step with the adopted NICs and the accept gate. Emits
    /// `.noUsableInterfaces` on the transition into it.
    private func updateStatus(_ state: inout State) -> Effect<Action> {
        guard isLive(state) else { return .none }
        if state.nics.isEmpty {
            guard state.status != .noUsableInterfaces else { return .none }
            state.status = .noUsableInterfaces
            return .send(.delegate(.noUsableInterfaces))
        }
        state.status = state.accepting ? .running : .starting
        return .none
    }

    /// Spec §8.4: denied-class send errors and no echo on any NIC 6.5 s into the session. Only NICs
    /// with no failed plane count as evidence: one that is down announces nothing, so its silence
    /// proves nothing (any echo, from any NIC, still disproves denial).
    private func checkLocalNetworkDenied(_ state: inout State, now: Date) -> Effect<Action> {
        guard state.deniedSendSeen, !state.localNetworkDeniedReported, let start = state.sessionStart,
              now.timeIntervalSince(start) > AutoInterfaceWire.multicastEchoTimeout,
              state.nics.values.contains(where: { $0.failed.isEmpty }),
              !state.nics.values.contains(where: { $0.firstEcho != nil }) else { return .none }
        state.localNetworkDeniedReported = true
        return .send(.delegate(.localNetworkDenied))
    }

    // MARK: Helpers

    private static func report(_ result: AutoSendResult, _ generation: Int, _ send: Send<Action>) async {
        if case let .failed(errno) = result, deniedErrnos.contains(errno) {
            await send(.sendFailed(errno: errno, generation: generation))
        }
    }

    /// Every `fe80:` address of the NIC, descoped (`AI:235-240`, `AI:80-85`).
    static func linkLocals(_ nic: AutoNIC) -> [String] {
        nic.linkLocals.filter { $0.hasPrefix("fe80:") }.map(AutoInterfaceWire.descope)
    }

    /// The address the NIC adopts: the last `fe80:` one, descoped (spec §5.5.6).
    static func adoptedLinkLocal(_ nic: AutoNIC) -> String? {
        AutoInterfaceConfig.selectLinkLocal(nic.linkLocals).map(AutoInterfaceWire.descope)
    }

    static func binding(_ nic: String, _ index: UInt32, _ linkLocal: String, _ config: AutoInterfaceConfig) -> AutoBinding {
        AutoBinding(
            nic: nic, index: index, linkLocal: linkLocal,
            group: AutoInterfaceWire.groupAddress(groupID: config.groupID, scope: config.scope, type: config.addressType),
            linkScope: config.scope == .link, discoveryPort: config.discoveryPort, dataPort: config.dataPort)
    }
}
