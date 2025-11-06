import Foundation
import ArgumentParser
import Diffalla

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a snapshot matches a directory"
    )

    @Argument(help: "Snapshot file to verify")
    var snapshot: String

    @Argument(help: "Directory to verify against")
    var directory: String

    @Flag(name: .long, help: "Verbose output (show all verified files)")
    var verbose: Bool = false

    func run() throws {
        print("Verify command - Not yet implemented")
        print("  Snapshot: \(snapshot)")
        print("  Directory: \(directory)")
        print("  Verbose: \(verbose)")
    }
}
