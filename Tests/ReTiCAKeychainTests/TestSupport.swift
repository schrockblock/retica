import Foundation

/// Blocks each arriving thread until `parties` threads have arrived, then releases them all.
/// Waits are bounded by `timeout`, so a regression that keeps a party from arriving can never
/// park the others forever (the test then fails on its own assertions instead of hanging).
final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let parties: Int
    private let timeout: DispatchTimeInterval
    private var arrived = 0

    init(parties: Int, timeout: DispatchTimeInterval = .seconds(5)) {
        self.parties = parties
        self.timeout = timeout
    }

    func arriveAndWait() {
        lock.lock()
        arrived += 1
        let isLast = arrived == parties
        lock.unlock()
        if isLast {
            for _ in 0..<parties { gate.signal() }
        }
        _ = gate.wait(timeout: .now() + timeout)
    }
}

final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
