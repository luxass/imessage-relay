import ArgumentParser
import Foundation
import RelayServer

@main
struct RelayOpenAPIExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-relay-openapi",
        abstract: "Export the generated OpenAPI description without starting the relay."
    )

    @Option(help: "Write JSON to this file instead of standard output.")
    var output: String?

    func run() throws {
        let data = try relayOpenAPIDocumentData()
        if let output {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}
