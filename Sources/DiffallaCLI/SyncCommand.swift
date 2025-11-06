import Foundation
import ArgumentParser
import Diffalla

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Synchronize two directories"
    )

    @Argument(help: "Source directory")
    var source: String

    @Argument(help: "Destination directory")
    var destination: String

    @Flag(name: .long, help: "Bidirectional sync (merge changes from both sides)")
    var bidirectional: Bool = false

    @Flag(name: .long, help: "Dry run (show what would be changed without syncing)")
    var dryRun: Bool = false

    @Option(name: .long, help: "Conflict resolution strategy (abort, source-wins, dest-wins, newer-wins)")
    var conflictResolution: String = "abort"

    @Flag(name: .long, help: "Delete files in destination that don't exist in source")
    var delete: Bool = false

    func run() throws {
        print("Sync command - Not yet implemented")
        print("  Source: \(source)")
        print("  Destination: \(destination)")
        print("  Bidirectional: \(bidirectional)")
        print("  Dry run: \(dryRun)")
        print("  Conflict resolution: \(conflictResolution)")
        print("  Delete: \(delete)")
    }
}
