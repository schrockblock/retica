import Foundation

/// Blocks each arriving thread until `parties` threads have arrived, then releases them all.
final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let parties: Int
    private var arrived = 0

    init(parties: Int) { self.parties = parties }

    func arriveAndWait() {
        lock.lock()
        arrived += 1
        let isLast = arrived == parties
        lock.unlock()
        if isLast {
            for _ in 0..<parties { gate.signal() }
        }
        gate.wait()
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
