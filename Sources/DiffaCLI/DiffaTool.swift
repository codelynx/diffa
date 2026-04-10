import Foundation
import ArgumentParser
import Diffa

@available(macOS 13.0, *)
struct DiffaTool: ParsableCommand {
    static let configuration: CommandConfiguration = {
        var subcommands: [ParsableCommand.Type] = [
            SnapshotCommand.self,
            CompareCommand.self,
            PatchCommand.self,
            SyncCommand.self,
            ExportCommand.self,
            VerifyCommand.self,
        ]
        #if canImport(Network)
        subcommands.append(contentsOf: [
            ServeCommand.self,
            PushCommand.self,
            PullCommand.self,
        ])
        #endif
        return CommandConfiguration(
            commandName: "diffa",
            abstract: "Snapshot, compare, patch, and sync directories",
            version: "0.12.0",
            subcommands: subcommands,
            helpNames: [.short, .long]
        )
    }()
}
