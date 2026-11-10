import Foundation
import ComposableArchitecture
#if canImport(Darwin)
import Darwin
#endif

// The AutoInterface socket driver (spec 2026-11-10-autointerface §5.3, socket table §4.4).
//
// Reference: RNS 1.6.0 `Interfaces/AutoInterface.py` (`AI`). The driver owns sockets only: NIC
// eligibility (§5.5), link-local selection, descoping (§4.3) and token checks belong to the reducer.

/// One NIC with at least one `fe80:` address, as `getifaddrs` reports it. Nothing is filtered here
/// except the address family and prefix: the reducer applies eligibility and `selectLinkLocal`.
public struct AutoNIC: Equatable, Sendable {
    public var name: String
    /// `if_nametoindex(name)`.
    public var index: UInt32
    /// Every `fe80:` address of the NIC, in getifaddrs order, as `inet_ntop` text with no scope.
    public var linkLocals: [String]

    public init(name: String, index: UInt32, linkLocals: [String]) {
        self.name = name
        self.index = index
        self.linkLocals = linkLocals
    }
}

/// What to bind on one NIC: the socket trio of §4.4.
public struct AutoBinding: Equatable, Sendable {
    public var nic: String
    public var index: UInt32
    /// The adopted link-local address (text). The unicast discovery and data sockets bind it.
    public var linkLocal: String
    /// The 16-byte multicast group (`AutoInterfaceWire.groupAddress`).
    public var group: [UInt8]
    /// Link scope binds the group socket with `sin6_scope_id = index`, any other scope with none
    /// (`AI:278-300`).
    public var linkScope: Bool
    /// Multicast discovery port. The unicast discovery socket binds `discoveryPort + 1` (`AI:174`).
    public var discoveryPort: UInt16
    public var dataPort: UInt16

    public init(
        nic: String, index: UInt32, linkLocal: String, group: [UInt8], linkScope: Bool,
        discoveryPort: UInt16, dataPort: UInt16
    ) {
        self.nic = nic
        self.index = index
        self.linkLocal = linkLocal
        self.group = group
        self.linkScope = linkScope
        self.discoveryPort = discoveryPort
        self.dataPort = dataPort
    }
}

/// The three receiving sockets of one NIC (§4.4).
public enum AutoPlane: Sendable, Equatable { case multicastDiscovery, unicastDiscovery, data }

/// Bind and read outcomes (`bound`, `bindFailed`, `readFailed`) are never dropped. Datagrams are:
/// a session buffers at most `AutoInterfaceDriver.eventBufferLimit` events for a consumer that is
/// not reading, and further datagrams are dropped, as a full kernel socket buffer drops them.
public enum AutoSocketEvent: Sendable, Equatable {
    /// Every plane of the NIC bound. Emitted once per `run` binding or `rebind` that fully succeeds.
    case bound(nic: String)
    /// One plane of one NIC failed to open or bind. Other NICs are unaffected. The data plane binds
    /// first: when it fails (`EADDRINUSE` is the same-host clash of §4.10) it is the only event and
    /// NEITHER discovery socket is opened, so a co-running rnsd or NomadNet keeps its unicast. When
    /// a discovery plane fails, the planes that did bind stay open.
    case bindFailed(nic: String, plane: AutoPlane, errno: Int32)
    /// One received datagram. `source` is `inet_ntop` text with no scope, `sourceScope` is the
    /// `sin6_scope_id` (§4.3.2). `payload` is the whole datagram (at most 8192 bytes).
    case datagram(nic: String, plane: AutoPlane, source: String, sourceScope: UInt32, payload: Data)
    /// `recvfrom` failed with something other than `EAGAIN`/`EINTR`. That socket is closed. The
    /// reducer recovers with `rebind`.
    case readFailed(nic: String, plane: AutoPlane, errno: Int32)
}

public enum AutoSendResult: Sendable, Equatable { case sent, failed(errno: Int32) }

/// Socket dependency for `AutoInterface`. The live value is POSIX over a private actor; tests of the
/// reducer inject a mock.
public struct AutoInterfaceDriver: Sendable {
    /// A `getifaddrs` snapshot of NICs with `fe80:` addresses.
    public var interfaces: @Sendable () -> [AutoNIC]
    /// Start a session: bind every binding, and stream events until `stop`. A second `run` ends
    /// the previous session (its stream finishes, its sockets close). Dropping the stream (consumer
    /// cancelled) ends the session too.
    public var run: @Sendable ([AutoBinding]) -> AsyncStream<AutoSocketEvent>
    /// Close the NIC's sockets (if any) and bind the binding afresh. Events read by the replaced
    /// sockets never surface after this returns. Address change or NIC added (§5.6 D1, D2). A no-op
    /// outside a session (before `run` or after `stop`).
    public var rebind: @Sendable (AutoBinding) async -> Void
    /// Close the NIC's sockets. NIC vanished (§5.6 D2).
    public var unbind: @Sendable (_ nic: String) async -> Void
    /// Send `token` to the NIC's group on `port` from an unbound socket with `IPV6_MULTICAST_IF`,
    /// destination scope 0 (`AI:504-513`). Fails with `ENXIO` for a NIC that is not bound.
    public var sendMulticast: @Sendable (_ nic: String, _ token: Data, _ port: UInt16) async -> AutoSendResult
    /// Send a datagram to `(addr, port, 0, index)` from the one shared unbound socket
    /// (`AI:490-499`, `AI:670-677`). Fails with `ENXIO` outside a session, so a send after `stop`
    /// cannot reopen the shared socket and leak it.
    public var sendUnicast: @Sendable (_ addr: String, _ index: UInt32, _ port: UInt16, _ datagram: Data) async -> AutoSendResult
    /// Close every socket and finish the stream.
    public var stop: @Sendable () async -> Void

    public init(
        interfaces: @escaping @Sendable () -> [AutoNIC],
        run: @escaping @Sendable ([AutoBinding]) -> AsyncStream<AutoSocketEvent>,
        rebind: @escaping @Sendable (AutoBinding) async -> Void,
        unbind: @escaping @Sendable (String) async -> Void,
        sendMulticast: @escaping @Sendable (String, Data, UInt16) async -> AutoSendResult,
        sendUnicast: @escaping @Sendable (String, UInt32, UInt16, Data) async -> AutoSendResult,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.interfaces = interfaces
        self.run = run
        self.rebind = rebind
        self.unbind = unbind
        self.sendMulticast = sendMulticast
        self.sendUnicast = sendUnicast
        self.stop = stop
    }
}

extension AutoInterfaceDriver {
    /// The most events a live session's stream buffers for a consumer that is not reading.
    static let eventBufferLimit = 512
    /// The most datagrams one read socket holds for its one pending delivery.
    static let pendingDatagramLimit = 256
    /// The most datagrams one read event takes from the kernel.
    static let maxDatagramsPerRead = 64
}

extension AutoInterfaceDriver: DependencyKey {
    public static var liveValue: AutoInterfaceDriver { live(deliveryGate: nil) }

    /// The live driver. `deliveryGate` is a test seam: it is awaited after a socket has read a batch
    /// and before the batch reaches the actor, so a test can hold a delivery stamped with an old
    /// generation across a `rebind`. `startGate` is awaited before a `run`'s start hops onto the
    /// actor, so a test can make one start arrive after a later `run` or `stop`. `socketQueue` is the
    /// serial queue the read sources (and their fd-closing cancel handlers) run on, so a test can
    /// occupy it. Production passes nil for all three.
    static func live(
        deliveryGate: (@Sendable () async -> Void)?,
        startGate: (@Sendable () async -> Void)? = nil,
        socketQueue: DispatchQueue? = nil
    ) -> AutoInterfaceDriver {
        #if canImport(Darwin)
        let actor = AutoSocketActor(
            deliveryGate: deliveryGate,
            queue: socketQueue ?? DispatchQueue(label: "retica.autointerface.sockets"))
        let ticket = SessionTicket()
        return AutoInterfaceDriver(
            interfaces: { AutoSocketActor.enumerateInterfaces() },
            run: { bindings in
                // Taken synchronously, so a `stop` (or a later `run`) issued before this session's
                // start reaches the actor wins: the start then finds its ticket stale.
                let t = ticket.bump()
                // Bounded, oldest kept: a full buffer refuses the NEW event, as a full kernel socket
                // buffer drops new datagrams. Keeping the oldest also means a refused yield names
                // exactly the event refused, so the actor can hold a refused bind or read outcome
                // back and yield it again (`flushControl`) instead of losing it. Unbounded, any LAN
                // host sending to the (unauthenticated) ports grew this buffer without limit.
                return AsyncStream(AutoSocketEvent.self,
                                   bufferingPolicy: .bufferingOldest(AutoInterfaceDriver.eventBufferLimit)) { continuation in
                    // Installed here, before the start can run, so a consumer that drops the stream
                    // early still retires the ticket and its start binds nothing. The strong capture
                    // of the actor is released when the stream terminates (onTermination runs once).
                    continuation.onTermination = { _ in
                        ticket.retire(t)
                        Task { await actor.terminated(ticket: t) }
                    }
                    Task {
                        if let startGate { await startGate() }
                        await actor.start(bindings, continuation: continuation, ticket: t, current: ticket)
                    }
                }
            },
            rebind: { await actor.rebind($0) },
            unbind: { await actor.unbind($0) },
            sendMulticast: { await actor.sendMulticast(nic: $0, token: $1, port: $2) },
            sendUnicast: { await actor.sendUnicast(addr: $0, index: $1, port: $2, datagram: $3) },
            stop: {
                _ = ticket.bump()
                await actor.stop()
            }
        )
        #else
        return AutoInterfaceDriver(
            interfaces: { [] }, run: { _ in .finished }, rebind: { _ in }, unbind: { _ in },
            sendMulticast: { _, _, _ in .failed(errno: 0) }, sendUnicast: { _, _, _, _ in .failed(errno: 0) },
            stop: {})
        #endif
    }

    public static let testValue = AutoInterfaceDriver(
        interfaces: unimplemented("AutoInterfaceDriver.interfaces", placeholder: []),
        run: unimplemented("AutoInterfaceDriver.run", placeholder: AsyncStream { $0.finish() }),
        rebind: unimplemented("AutoInterfaceDriver.rebind"),
        unbind: unimplemented("AutoInterfaceDriver.unbind"),
        sendMulticast: unimplemented("AutoInterfaceDriver.sendMulticast", placeholder: .failed(errno: 0)),
        sendUnicast: unimplemented("AutoInterfaceDriver.sendUnicast", placeholder: .failed(errno: 0)),
        stop: unimplemented("AutoInterfaceDriver.stop")
    )
}

extension DependencyValues {
    public var autoInterfaceDriver: AutoInterfaceDriver {
        get { self[AutoInterfaceDriver.self] }
        set { self[AutoInterfaceDriver.self] = newValue }
    }
}

#if canImport(Darwin)
/// Orders `run` against `stop` across the hop onto the actor: each takes a ticket synchronously,
/// and a start whose ticket is no longer current does nothing.
private final class SessionTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func bump() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func isCurrent(_ t: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == t
    }

    /// Makes `t` stale if it is still current (its stream terminated). A later ticket is untouched.
    func retire(_ t: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if value == t { value &+= 1 }
    }
}

/// Owns every AutoInterface socket of one driver (spec §5.3, live-actor rules 1-5).
///
/// Each NIC's read sockets are stamped with a generation taken when they were bound. A datagram is
/// read on the dispatch queue and hops onto the actor in a `Task`, so it can arrive after `rebind`,
/// `unbind` or `stop` replaced the socket that read it. `deliver` drops it unless the NIC's current
/// generation still equals the stamp: the `NWConnectionActor` lesson (`TCPConnection.swift:97-112`),
/// where a superseded connection's callback finished the new stream. A per-NIC stamp (rather than one
/// actor-wide value) keeps a rebind of one NIC from discarding traffic in flight on the others.
private actor AutoSocketActor {
    private struct NICSockets {
        var binding: AutoBinding
        var generation: UInt64
        var sources: [AutoPlane: ReadSocket]
        /// Unbound announce socket with `IPV6_MULTICAST_IF`, opened on first use. Never read, so it
        /// has no dispatch source and is closed directly.
        var multicastSender: Int32
    }

    /// A read socket's dispatch source, and a semaphore its cancel handler signals once it has
    /// closed the fd.
    private struct ReadSocket {
        let source: DispatchSourceRead
        let closed: DispatchSemaphore
    }

    /// What one read socket has read and not yet handed to the actor. At most ONE delivery Task per
    /// socket runs at a time: reads made while it is pending coalesce here, up to
    /// `pendingDatagramLimit`, and the rest are dropped (UDP semantics). One Task per read batch,
    /// with the actor slow, grew without bound under a flood.
    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [ReceivedDatagram] = []
        private var error: Int32?
        private var scheduled = false

        /// Adds a batch. Returns true when the caller must start the delivery Task (none runs).
        func put(_ batch: [ReceivedDatagram], error: Int32?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let room = max(0, AutoInterfaceDriver.pendingDatagramLimit - pending.count)
            pending.append(contentsOf: batch.prefix(room))
            if let error, self.error == nil { self.error = error }
            if scheduled { return false }
            scheduled = true
            return true
        }

        /// Takes everything pending. Nil when there is nothing: the Task ends, and the next `put`
        /// starts a new one (one lock, so no batch is stranded between the two).
        func take() -> (datagrams: [ReceivedDatagram], error: Int32?)? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty || error != nil else {
                scheduled = false
                return nil
            }
            let out = (pending, error)
            pending = []
            error = nil
            return out
        }
    }

    private static let readBufferSize = AutoInterfaceWire.dataRecvSize
    private static let maxDatagramsPerRead = AutoInterfaceDriver.maxDatagramsPerRead

    private let deliveryGate: (@Sendable () async -> Void)?
    private let queue: DispatchQueue
    private var continuation: AsyncStream<AutoSocketEvent>.Continuation?
    /// The ticket of the session `continuation` belongs to.
    private var activeTicket: UInt64 = 0
    private var generation: UInt64 = 0
    private var nics: [String: NICSockets] = [:]
    /// Bind and read outcomes the full stream refused, oldest first. Yielded again, ahead of any
    /// datagram, at every actor entry, so none is lost (the reducer's retries depend on them).
    private var pendingControl: [AutoSocketEvent] = []
    /// The one shared unbound socket for every unicast send (§5.3.3), opened on first use.
    private var unicastSender: Int32 = -1

    init(deliveryGate: (@Sendable () async -> Void)?, queue: DispatchQueue) {
        self.deliveryGate = deliveryGate
        self.queue = queue
    }

    deinit {
        for nic in nics.values {
            for socket in nic.sources.values { socket.source.cancel() }
            if nic.multicastSender >= 0 { close(nic.multicastSender) }
        }
        if unicastSender >= 0 { close(unicastSender) }
    }

    // MARK: Session

    func start(
        _ bindings: [AutoBinding], continuation: AsyncStream<AutoSocketEvent>.Continuation,
        ticket: UInt64, current: SessionTicket
    ) {
        // The ticket check comes first. Starts hop through unstructured Tasks in no guaranteed order,
        // so a stale start (a later `run` or a `stop` was issued after it) can arrive after the
        // session that superseded it: it must finish only its own stream, not tear that session down.
        guard current.isCurrent(ticket) else {
            continuation.finish()
            return
        }
        teardownAll()
        activeTicket = ticket
        self.continuation = continuation
        for binding in bindings { bind(binding) }
    }

    func stop() {
        teardownAll()
    }

    /// A stream terminated (consumer dropped it, or the driver finished it). Releases the sockets only
    /// if that stream is still the live session's.
    func terminated(ticket t: UInt64) {
        guard t == activeTicket, continuation != nil else { return }
        teardownAll()
    }

    private func teardownAll() {
        generation &+= 1
        for nic in Array(nics.keys) { teardown(nic) }
        if unicastSender >= 0 {
            close(unicastSender)
            unicastSender = -1
        }
        let c = continuation
        continuation = nil
        pendingControl = []
        c?.finish()
    }

    // MARK: Yielding

    /// Queues a bind or read outcome and yields what the stream will take.
    private func emitControl(_ event: AutoSocketEvent) {
        guard continuation != nil else { return }
        pendingControl.append(event)
        flushControl()
    }

    /// Yields held-back control events in order. True when none is left (the stream has room).
    @discardableResult
    private func flushControl() -> Bool {
        guard let continuation else { return false }
        while let first = pendingControl.first {
            switch continuation.yield(first) {
            case .enqueued: pendingControl.removeFirst()
            case .dropped: return false
            case .terminated:
                pendingControl = []
                return false
            @unknown default: return false
            }
        }
        return true
    }

    // MARK: Per-NIC binding

    func rebind(_ binding: AutoBinding) {
        guard continuation != nil else { return }
        teardown(binding.nic)
        bind(binding)
    }

    func unbind(_ nic: String) {
        generation &+= 1
        teardown(nic)
    }

    private func teardown(_ nic: String) {
        guard let entry = nics.removeValue(forKey: nic) else { return }
        // The fd of each read socket is closed in its source's cancel handler, never here. Wait for
        // those closes: the cancel handler runs later on `queue`, and a `rebind` that binds the data
        // port before the old fd is closed fails EADDRINUSE (no reuse options on that plane). A probe
        // of 200 back-to-back rebinds failed 166 without this wait. The wait cannot deadlock: nothing
        // on `queue` waits for the actor (the event handler only drains and spawns a Task).
        for socket in entry.sources.values { socket.source.cancel() }
        for socket in entry.sources.values { socket.closed.wait() }
        if entry.multicastSender >= 0 { close(entry.multicastSender) }
    }

    private func bind(_ binding: AutoBinding) {
        // A duplicate NIC name in one `run` would otherwise overwrite the entry and leak its fds.
        teardown(binding.nic)
        generation &+= 1
        let gen = generation
        var entry = NICSockets(binding: binding, generation: gen, sources: [:], multicastSender: -1)
        var allBound = true
        // The data plane FIRST, and when it fails open neither discovery socket. Those carry
        // SO_REUSEPORT, and on Darwin the most recently bound reuseport socket receives all unicast
        // to (ll, port): a unicast discovery socket of ours, re-created by every D3 retry, took every
        // reverse announce meant for the rnsd or NomadNet holding the data port (0 of 20 reached it,
        // probe /tmp/ReTiCA/reuseport_unicast_probe.py). The reference never gets there: its data
        // clash panics the process (`RT:1307-1311`). A failed multicast join is still reported
        // after a good data bind, for the reducer's skip (spec R11).
        planes: for plane in [AutoPlane.data, .multicastDiscovery, .unicastDiscovery] {
            switch Self.openReceiver(plane, binding) {
            case let .success(fd):
                entry.sources[plane] = makeSource(fd: fd, nic: binding.nic, plane: plane, generation: gen)
            case let .failure(err):
                allBound = false
                emitControl(.bindFailed(nic: binding.nic, plane: plane, errno: err.code))
                if plane == .data { break planes }
            }
        }
        nics[binding.nic] = entry
        if allBound { emitControl(.bound(nic: binding.nic)) }
    }

    private func makeSource(fd: Int32, nic: String, plane: AutoPlane, generation gen: UInt64) -> ReadSocket {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let closed = DispatchSemaphore(value: 0)
        let gate = deliveryGate
        let mailbox = Mailbox()
        source.setEventHandler { [weak self, weak source] in
            let (datagrams, error) = Self.drain(fd)
            // A hard read error would make the source fire for ever: close this socket now.
            if error != nil { source?.cancel() }
            guard !datagrams.isEmpty || error != nil else { return }
            // A delivery already pending picks this batch up (see `Mailbox`).
            guard mailbox.put(datagrams, error: error) else { return }
            Task {
                while let batch = mailbox.take() {
                    if let gate { await gate() }
                    await self?.deliver(nic: nic, plane: plane, generation: gen,
                                        datagrams: batch.datagrams, error: batch.error)
                }
            }
        }
        source.setCancelHandler {
            close(fd)
            closed.signal()
        }
        source.resume()
        return ReadSocket(source: source, closed: closed)
    }

    private func deliver(
        nic: String, plane: AutoPlane, generation gen: UInt64,
        datagrams: [ReceivedDatagram], error: Int32?
    ) {
        // Stale: read by a socket that `rebind`/`unbind`/`stop` has since replaced or closed.
        guard let continuation, let entry = nics[nic], entry.generation == gen else { return }
        // Held-back control events go first; while any is still refused the stream is full and
        // these datagrams would be refused too.
        if flushControl() {
            for d in datagrams {
                let result = continuation.yield(.datagram(
                    nic: nic, plane: plane, source: d.source, sourceScope: d.scope, payload: d.payload))
                if case .dropped = result { break }   // full: the rest would drop as well
            }
        }
        if let error {
            nics[nic]?.sources[plane] = nil
            emitControl(.readFailed(nic: nic, plane: plane, errno: error))
        }
    }

    // MARK: Sends

    func sendMulticast(nic: String, token: Data, port: UInt16) -> AutoSendResult {
        // Every announce tick passes here, so a control event held back by a flood that has since
        // ended is yielded within 1.6 s even if no datagram arrives.
        flushControl()
        guard var entry = nics[nic] else { return .failed(errno: ENXIO) }
        if entry.multicastSender < 0 {
            switch Self.openMulticastSender(index: entry.binding.index) {
            case let .success(fd):
                entry.multicastSender = fd
                nics[nic] = entry
            case let .failure(err):
                return .failed(errno: err.code)
            }
        }
        // Destination scope 0, as the reference sends (`AI:504-513`, spec §4.4.1).
        return Self.send(fd: entry.multicastSender, token, to: entry.binding.group, port: port, scope: 0)
    }

    func sendUnicast(addr: String, index: UInt32, port: UInt16, datagram: Data) -> AutoSendResult {
        // Outside a session: `teardownAll` closed the shared sender, and reopening it here would leak
        // it until the next session's teardown. Same answer as a multicast send on an unbound NIC.
        guard continuation != nil else { return .failed(errno: ENXIO) }
        flushControl()
        guard let bytes = Self.parseIPv6(addr) else { return .failed(errno: EINVAL) }
        if unicastSender < 0 {
            switch Self.openSocket() {
            case let .success(fd): unicastSender = fd
            case let .failure(err): return .failed(errno: err.code)
            }
        }
        return Self.send(fd: unicastSender, datagram, to: bytes, port: port, scope: index)
    }

    // MARK: POSIX helpers (nonisolated, no actor state)

    struct SocketError: Error { let code: Int32 }

    struct ReceivedDatagram: Sendable {
        let source: String
        let scope: UInt32
        let payload: Data
    }

    /// `getifaddrs`, keeping `AF_INET6` entries whose `inet_ntop` text starts with `fe80:` (§5.3.1).
    /// NICs come in order of first appearance; addresses keep getifaddrs order.
    static func enumerateInterfaces() -> [AutoNIC] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var order: [String] = []
        var addresses: [String: [String]] = [:]
        var cursor = head
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET6 else { continue }
            let sin6 = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in6.self)
            let text = AutoInterfaceWire.formatIPv6(withUnsafeBytes(of: sin6.sin6_addr) { Array($0) })
            guard text.hasPrefix("fe80:") else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if addresses[name] == nil { order.append(name) }
            addresses[name, default: []].append(text)
        }
        return order.map { AutoNIC(name: $0, index: if_nametoindex($0), linkLocals: addresses[$0] ?? []) }
    }

    /// Opens and binds one receiving socket per the §4.4 table.
    private static func openReceiver(_ plane: AutoPlane, _ b: AutoBinding) -> Result<Int32, SocketError> {
        let address: [UInt8]
        let port: UInt16
        let scope: UInt32
        switch plane {
        case .multicastDiscovery:
            guard b.group.count == 16 else { return .failure(SocketError(code: EINVAL)) }
            address = b.group
            port = b.discoveryPort
            scope = b.linkScope ? b.index : 0
        case .unicastDiscovery, .data:
            guard let ll = parseIPv6(b.linkLocal) else { return .failure(SocketError(code: EINVAL)) }
            address = ll
            if plane == .data {
                port = b.dataPort
            } else {
                // `discoveryPort + 1` (`AI:174`). At 65535 it has no valid value: refuse rather than
                // wrap to 0, which would bind an ephemeral port no peer sends to.
                let (next, overflow) = b.discoveryPort.addingReportingOverflow(1)
                guard !overflow else { return .failure(SocketError(code: EINVAL)) }
                port = next
            }
            scope = b.index
        }
        let fd: Int32
        switch openSocket() {
        case let .success(s): fd = s
        case let .failure(e): return .failure(e)
        }
        func fail() -> Result<Int32, SocketError> {
            let code = errno
            close(fd)
            return .failure(SocketError(code: code))
        }
        // The data socket gets NO reuse options (`AI:337-347`, `allow_reuse_address=False`): a second
        // instance on the same data port must fail `EADDRINUSE` rather than split unicast (§4.10, R2).
        if plane != .data {
            guard setInt(fd, SOL_SOCKET, SO_REUSEADDR, 1), setInt(fd, SOL_SOCKET, SO_REUSEPORT, 1) else { return fail() }
        }
        if plane == .multicastDiscovery {
            guard setInt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, Int32(bitPattern: b.index)) else { return fail() }
            var mreq = ipv6_mreq()
            withUnsafeMutableBytes(of: &mreq.ipv6mr_multiaddr) { $0.copyBytes(from: address) }
            mreq.ipv6mr_interface = b.index
            let joined = setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, socklen_t(MemoryLayout<ipv6_mreq>.size))
            guard joined == 0 else { return fail() }
        }
        var sa = sockaddr(address, port: port, scope: scope)
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard rc == 0 else { return fail() }
        return .success(fd)
    }

    private static func openMulticastSender(index: UInt32) -> Result<Int32, SocketError> {
        switch openSocket() {
        case let .failure(e): return .failure(e)
        case let .success(fd):
            guard setInt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, Int32(bitPattern: index)) else {
                let code = errno
                close(fd)
                return .failure(SocketError(code: code))
            }
            return .success(fd)
        }
    }

    /// `socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)` with `O_NONBLOCK`.
    private static func openSocket() -> Result<Int32, SocketError> {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(SocketError(code: errno)) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            close(fd)
            return .failure(SocketError(code: code))
        }
        return .success(fd)
    }

    private static func setInt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var v = value
        return setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func sockaddr(_ address: [UInt8], port: UInt16, scope: UInt32) -> sockaddr_in6 {
        var sa = sockaddr_in6()
        sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sa.sin6_family = sa_family_t(AF_INET6)
        sa.sin6_port = port.bigEndian
        sa.sin6_scope_id = scope
        withUnsafeMutableBytes(of: &sa.sin6_addr) { $0.copyBytes(from: address) }
        return sa
    }

    private static func send(fd: Int32, _ data: Data, to address: [UInt8], port: UInt16, scope: UInt32) -> AutoSendResult {
        var sa = sockaddr(address, port: port, scope: scope)
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        return sent == data.count ? .sent : .failed(errno: sent < 0 ? errno : EMSGSIZE)
    }

    /// Text to 16 bytes. Any `%scope` suffix is ignored (the scope travels separately).
    private static func parseIPv6(_ text: String) -> [UInt8]? {
        let base = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        var addr = in6_addr()
        guard inet_pton(AF_INET6, base, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    /// Reads every pending datagram (up to a bound) from a non-blocking socket. Returns the hard
    /// error, if any, that stopped the reading.
    private static func drain(_ fd: Int32) -> ([ReceivedDatagram], Int32?) {
        var out: [ReceivedDatagram] = []
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while out.count < maxDatagramsPerRead {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                    }
                }
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return (out, nil) }
                return (out, code)
            }
            guard Int32(from.ss_family) == AF_INET6 else { continue }
            let sin6 = withUnsafeBytes(of: from) { $0.loadUnaligned(as: sockaddr_in6.self) }
            // inet_ntop text with no scope, exactly what the reference's recvfrom tuple carries
            // (spec §4.3.2), so the reducer's token check hashes the same string.
            let source = AutoInterfaceWire.formatIPv6(withUnsafeBytes(of: sin6.sin6_addr) { Array($0) })
            out.append(ReceivedDatagram(source: source, scope: sin6.sin6_scope_id, payload: Data(buffer[0..<n])))
        }
        return (out, nil)
    }
}
#endif
