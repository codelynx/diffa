import Foundation
import ArgumentParser
import Diffalla

@available(macOS 14.0, *)
struct DiffallaTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diffalla",
        abstract: "Snapshot, compare, patch, and sync directories",
        version: "0.1.0",
        subcommands: [
            SnapshotCommand.self,
            CompareCommand.self,
            PatchCommand.self,
            SyncCommand.self,
            ExportCommand.self,
            VerifyCommand.self
        ],
        helpNames: [.short, .long]
    )
}
