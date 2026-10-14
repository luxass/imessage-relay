import Foundation
import RelayServer

func export() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let checking = arguments.first == "--check"
    let paths = checking ? Array(arguments.dropFirst()) : arguments
    if paths.count > 1 || paths.first?.hasPrefix("--") == true { throw ExportError.usage }
    let output = URL(fileURLWithPath: paths.first ?? "docs/public/openapi.json")
    let document = try relayOpenAPIDocument()
    if checking {
        guard let existing = try? Data(contentsOf: output), existing == document else {
            throw ExportError.stale(output.path)
        }
        print("Generated OpenAPI is up to date: \(output.path)")
    } else {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: output, options: .atomic)
        print("Generated OpenAPI: \(output.path)")
    }
}

do {
    try export()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

enum ExportError: Error, CustomStringConvertible {
    case usage
    case stale(String)
    var description: String {
        switch self {
        case .usage: "Usage: swift run RelayOpenAPI [--check] [output-path]"
        case .stale(let path): "\(path) is stale. Run swift run RelayOpenAPI. Do not edit the generated JSON."
        }
    }
}
