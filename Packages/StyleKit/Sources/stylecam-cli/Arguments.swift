import Foundation

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: some Sequence<String>, flags known: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { throw UsageError(description: "unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            if known.contains(name) {
                flags.insert(name)
            } else if let value = iterator.next() {
                values[name] = value
            } else {
                throw UsageError(description: "--\(name) needs a value")
            }
        }
    }

    func string(_ name: String) -> String? {
        values[name]
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name] else { throw UsageError(description: "missing --\(name)") }
        return value
    }

    func flag(_ name: String) -> Bool {
        flags.contains(name)
    }

    func int(_ name: String) throws -> Int? {
        try values[name].map { value in
            guard let number = Int(value) else { throw UsageError(description: "--\(name) expects an integer") }
            return number
        }
    }

    func float(_ name: String) throws -> Float? {
        try values[name].map { value in
            guard let number = Float(value) else { throw UsageError(description: "--\(name) expects a number") }
            return number
        }
    }

    func positiveNumber(_ name: String) throws -> Double? {
        try values[name].map { value in
            guard let number = Double(value), number.isFinite, number > 0 else {
                throw UsageError(description: "--\(name) must be a positive number")
            }
            return number
        }
    }

    func url(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required(name))
    }

    func choice<T: RawRepresentable>(_ name: String, as type: T.Type) throws -> T? where T.RawValue == String {
        try values[name].map { value in
            guard let choice = T(rawValue: value) else { throw UsageError(description: "invalid --\(name) \(value)") }
            return choice
        }
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded()))]
}

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func format(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}
