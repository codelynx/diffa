import Foundation
import ArgumentParser
import Diffalla

struct CompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two snapshots or directories"
    )

    @Argument(help: "Source snapshot or directory")
    var source: String

    @Argument(help: "Destination snapshot or directory")
    var destination: String

    @Flag(name: .long, help: "Show only summary (files added/removed/modified counts)")
    var summary: Bool = false

    @Flag(name: .long, help: "Show detailed differences")
    var detailed: Bool = false

    @Option(name: .shortAndLong, help: "Output format (text, json, html)")
    var format: String = "text"

    func run() throws {
        print("Compare command - Not yet implemented")
        print("  Source: \(source)")
        print("  Destination: \(destination)")
        print("  Summary only: \(summary)")
        print("  Detailed: \(detailed)")
        print("  Format: \(format)")
    }
}
