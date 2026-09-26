import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let ifID = InterfaceID("tcp-1")
private let dest = Data(repeating: 0xD1, count: 16)
private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// One connected interface and a destination learned on it, `hops` away.
private func stateWithLearnedDestination(_ recipient: Identity, hops: UInt8 = 0) -> Transport.State {
    var state = Transport.State()
    state.interfaces[ifID] = .default
    state.learned[dest] = LearnedDestination(identity: recipient, appData: nil, ratchet: nil,
                                             interfaceID: ifID, hops: hops, nextHop: nil,
                                             announceEmitted: 0, learnedAt: now)
    return state
}

@MainActor
private func makeStore(_ initial: Transport.State) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = .constant(now)
    }
    store.exhaustivity = .off
    return store
}

/// Sends to `dest` and returns the raw packet Transport transmitted.
@MainActor
private func sendAndCapture(_ store: TestStore<Transport.State, Transport.Action>, token: Data?) async -> Data {
    let sent = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: dest, plaintext: Data("hello".utf8), receiptToken: token))
    await store.receive { action in
        guard case let .delegate(.transmit(_, raw)) = action else { return false }
        sent.setValue(raw)
        return true
    }
    return sent.value ?? Data()
}

@Test @MainActor func receiptTableSendWithATokenRecordsAReceipt() async throws {
    let recipient = Identity()
    let token = Data("message-hash".utf8)
    let store = makeStore(stateWithLearnedDestination(recipient))
    let raw = await sendAndCapture(store, token: token)
    let packetHash = try #require(Packet(raw: raw)).packetHash
    #expect(store.state.pendingReceipts == [
        Data(packetHash.prefix(16)): Transport.State.PendingReceipt(
            packetHash: packetHash, token: token, identity: recipient,
            expiresAt: now.addingTimeInterval(Transport.receiptTimeoutBase + Transport.receiptTimeoutPerHop)),
    ])
}

@Test @MainActor func receiptTableSendWithoutATokenRecordsNothing() async {
    let store = makeStore(stateWithLearnedDestination(Identity()))
    _ = await sendAndCapture(store, token: nil)
    #expect(store.state.pendingReceipts.isEmpty)
}

@Test @MainActor func receiptTableExpiryScalesWithHops() async throws {
    let store = makeStore(stateWithLearnedDestination(Identity(), hops: 3))
    let raw = await sendAndCapture(store, token: Data([1]))
    let key = Data(try #require(Packet(raw: raw)).packetHash.prefix(16))
    #expect(store.state.pendingReceipts[key]?.expiresAt
            == now.addingTimeInterval(Transport.receiptTimeoutBase + 3 * Transport.receiptTimeoutPerHop))
}

/// A resend is a new packet (new ephemeral ciphertext, new hash) with its own receipt, under the
/// same token — so a proof for EITHER copy confirms the message.
@Test @MainActor func receiptTableResendKeepsBothReceiptsUnderOneToken() async throws {
    let store = makeStore(stateWithLearnedDestination(Identity()))
    let token = Data([0xAB])
    let first = await sendAndCapture(store, token: token)
    let second = await sendAndCapture(store, token: token)
    let k1 = Data(try #require(Packet(raw: first)).packetHash.prefix(16))
    let k2 = Data(try #require(Packet(raw: second)).packetHash.prefix(16))
    #expect(k1 != k2)
    #expect(store.state.pendingReceipts.count == 2)
    #expect(store.state.pendingReceipts[k1]?.token == token)
    #expect(store.state.pendingReceipts[k2]?.token == token)
}

/// Expiry removes receipts at or past their deadline and emits NOTHING: the LXMF retry timer stays
/// the only failure authority.
@Test @MainActor func receiptTableMaintenanceTickDropsExpiredReceiptsSilently() async {
    let prover = Identity()
    func receipt(_ byte: UInt8, expiresAt: Date) -> (Data, Transport.State.PendingReceipt) {
        let hash = Data(repeating: byte, count: 32)
        return (Data(hash.prefix(16)),
                Transport.State.PendingReceipt(packetHash: hash, token: Data([byte]), identity: prover,
                                               expiresAt: expiresAt))
    }
    let past = receipt(0x01, expiresAt: now.addingTimeInterval(-1))
    let exact = receipt(0x02, expiresAt: now)
    let future = receipt(0x03, expiresAt: now.addingTimeInterval(1))
    var initial = Transport.State()
    initial.pendingReceipts = [past.0: past.1, exact.0: exact.1, future.0: future.1]
    let store = makeStore(initial)
    store.exhaustivity = .on   // any delegate from expiry is an unexpected action
    await store.send(.maintenanceTick) {
        $0.pendingReceipts = [future.0: future.1]
    }
}

@Test @MainActor func receiptTableAtCapacityEvictsTheSoonestExpiry() async throws {
    var initial = stateWithLearnedDestination(Identity())
    let filler = Identity()
    var soonestKey = Data()
    for i in 0..<Transport.maxPendingReceipts {
        var hash = Data(repeating: 0xEE, count: 32)
        hash[0] = UInt8(i & 0xFF)
        hash[1] = UInt8(i >> 8)
        let key = Data(hash.prefix(16))
        let expiresAt = i == 500 ? now.addingTimeInterval(1) : now.addingTimeInterval(1000 + Double(i))
        if i == 500 { soonestKey = key }
        initial.pendingReceipts[key] = Transport.State.PendingReceipt(packetHash: hash, token: Data([0]),
                                                                      identity: filler, expiresAt: expiresAt)
    }
    let store = makeStore(initial)
    let raw = await sendAndCapture(store, token: Data([0x77]))
    let newKey = Data(try #require(Packet(raw: raw)).packetHash.prefix(16))
    #expect(store.state.pendingReceipts.count == Transport.maxPendingReceipts)
    #expect(store.state.pendingReceipts[soonestKey] == nil)
    #expect(store.state.pendingReceipts[newKey]?.token == Data([0x77]))
}
