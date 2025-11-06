import Foundation
import ArgumentParser
import Diffa

@available(macOS 13.0, *)
struct DiffaTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diffa",
        abstract: "Snapshot, compare, patch, and sync directories",
        version: "0.10.0",
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
