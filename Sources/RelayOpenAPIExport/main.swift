import ArgumentParser
import Foundation
import RelayServer

@main
struct RelayOpenAPIExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-relay-openapi",
        abstract: "Export or check the generated OpenAPI description without starting the relay."
    )

    @Option(help: "Write JSON to this file instead of standard output.")
    var output: String?

    @Option(help: "Compare generated JSON with this file without writing it.")
    var check: String?

    func validate() throws {
        guard output == nil || check == nil else {
            throw ValidationError("Use --output or --check, not both.")
        }
    }

    func run() throws {
        let data = try relayOpenAPIDocumentData()
        if let check {
            guard try Data(contentsOf: URL(fileURLWithPath: check)) == data else {
                throw ValidationError("The OpenAPI document is out of date. Regenerate it with --output.")
            }
        } else if let output {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}
