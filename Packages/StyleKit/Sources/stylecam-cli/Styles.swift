import Foundation
import StyleKit

func listStyles(_ arguments: Arguments) async throws {
    let predictor = try await StylePredictor.load(from: ModelStore(directory: try arguments.url("models")))
    let library = try StyleLibrary(catalogDirectory: try arguments.url("styles"), predictor: predictor)
    var vectors: [String: [Float]] = [:]
    for style in await library.styles {
        let start = now()
        let vector = try await library.vector(for: style.id)
        vectors[style.id] = vector.values
        if !arguments.flag("json") {
            print(style.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                + "norm \(format(Double(vector.norm), 4))  \(format((now() - start) * 1000, 1)) ms")
        }
    }
    if arguments.flag("json") {
        let data = try JSONSerialization.data(withJSONObject: vectors, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
