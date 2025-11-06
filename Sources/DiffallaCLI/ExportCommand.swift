import Foundation
import ArgumentParser
import Diffalla

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export comparison results in various formats"
    )

    @Argument(help: "Source snapshot or directory")
    var source: String

    @Argument(help: "Destination snapshot or directory")
    var destination: String

    @Option(name: .shortAndLong, help: "Output format (text, json, html, diff)")
    var format: String = "text"

    @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
    var output: String?

    func run() throws {
        print("Export command - Not yet implemented")
        print("  Source: \(source)")
        print("  Destination: \(destination)")
        print("  Format: \(format)")
        print("  Output: \(output ?? "<stdout>")")
    }
}
