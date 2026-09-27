import Foundation

/// Counts frames between admission and output.
final class InFlightGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var limit = 1

    var current: Int {
        condition.withLock { count }
    }

    func setLimit(_ value: Int) {
        condition.withLock {
            limit = value
            condition.broadcast()
        }
    }

    func tryEnter() -> Bool {
        condition.withLock {
            guard count < limit else { return false }
            count += 1
            return true
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
