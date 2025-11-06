import Foundation
import ArgumentParser
import Diffalla

/// Diffalla - File system comparison, patching, and synchronization tool
@main
struct DiffallaTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diffalla",
        abstract: "File system comparison, patching, and synchronization tool",
        version: "0.1.0",
        subcommands: [],
        defaultSubcommand: nil
    )

    func run() throws {
        print("""
        Diffalla - File system comparison, patching, and synchronization tool

        Run 'diffalla --help' to see available commands.
        """)
    }
}
