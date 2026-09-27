import Foundation

struct Options {
    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    private var values: [String: String] = [:]

    init(_ arguments: [String], allowed: Set<String>) throws {
        var remaining = arguments.makeIterator()
        while let flag = remaining.next() {
            guard allowed.contains(flag) else { throw UsageError(description: "Unknown option \(flag)") }
            guard let value = remaining.next() else { throw UsageError(description: "Missing value for \(flag)") }
            values[flag] = value
        }
    }

    subscript(flag: String) -> String? {
        values[flag]
    }

    func required(_ flag: String) throws -> String {
        guard let value = values[flag] else { throw UsageError(description: "Missing \(flag)") }
        return value
    }

    func positiveNumber(_ flag: String) throws -> Double? {
        guard let value = values[flag] else { return nil }
        guard let number = Double(value), number > 0 else { throw UsageError(description: "\(flag) must be a positive number") }
        return number
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
