import Foundation

/// Counts frames in a stage of the pipeline. `enter` blocks while the stage is full.
final class InFlightGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var limit: Int

    init(limit: Int = .max) {
        self.limit = limit
    }

    func setLimit(_ value: Int) {
        condition.withLock {
            limit = value
            condition.broadcast()
        }
    }

    func enter() {
        condition.withLock {
            while count >= limit { condition.wait() }
            count += 1
        }
    }

    func leave() {
        condition.withLock {
            count -= 1
            condition.broadcast()
        }
    }

    func waitUntilEmpty() {
        condition.withLock {
            while count > 0 { condition.wait() }
        }
    }
}
