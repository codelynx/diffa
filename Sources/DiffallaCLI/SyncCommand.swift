import Foundation
import ArgumentParser
import Diffalla

@available(macOS 13.0, *)
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

    @Option(name: .long, help: "Conflict resolution strategy (error, newest, source-wins, dest-wins)")
    var conflictResolution: String = "error"

    @Flag(name: .long, help: "Delete files in destination that don't exist in source (unidirectional only)")
    var delete: Bool = false

    @Flag(name: .long, help: "Show progress during sync")
    var progress: Bool = false

    func run() throws {
        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await performSync()
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let error = thrownError {
            throw error
        }
    }

    func performSync() async throws {
        // Validate that --delete is not used with --bidirectional
        if bidirectional && delete {
            print("Error: --delete cannot be used with --bidirectional")
            print("Bidirectional sync merges changes from both sides and should not delete files.")
            throw ExitCode(2)
        }

        // Validate directories
        let sourceURL = URL(fileURLWithPath: source)
        let destURL = URL(fileURLWithPath: destination)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalidDirectory(source)
        }

        guard FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalidDirectory(destination)
        }

        // Parse conflict resolution strategy
        let conflictStrategy = try parseConflictResolution(conflictResolution)

        // Create sync options
        let options = SyncOptions(
            dryRun: dryRun,
            verifyAfterSync: false,
            deleteExtraFiles: delete,
            preserveMetadata: true
        )

        // Create synchronizer
        let synchronizer = Synchronizer()

        // Perform sync
        let result: SyncResult

        if bidirectional {
            print("Performing bidirectional sync...")
            print("  Directory A: \(source)")
            print("  Directory B: \(destination)")
            print("  Conflict strategy: \(conflictResolution)")
            if dryRun {
                print("  Mode: DRY RUN (no changes will be made)")
            }
            print()

            result = try await synchronizer.syncBidirectional(
                a: sourceURL,
                b: destURL,
                conflictResolution: conflictStrategy,
                options: options,
                progress: progress ? { prog in
                    self.showProgress(prog)
                } : nil
            )
        } else {
            print("Performing unidirectional sync...")
            print("  Source: \(source)")
            print("  Destination: \(destination)")
            if delete {
                print("  Delete extra files: Yes")
            }
            if dryRun {
                print("  Mode: DRY RUN (no changes will be made)")
            }
            print()

            result = try await synchronizer.syncUnidirectional(
                source: sourceURL,
                destination: destURL,
                options: options,
                progress: progress ? { prog in
                    self.showProgress(prog)
                } : nil
            )
        }

        // Show results
        print("\n✓ Sync completed successfully")
        print("\nSummary:")
        print("  Files copied:  \(result.filesCopied)")
        print("  Files deleted: \(result.filesDeleted)")
        print("  Files moved:   \(result.filesMoved)")
        print("  Bytes transferred: \(formatBytes(result.bytesTransferred))")
        print("  Duration: \(String(format: "%.2f", result.duration))s")

        if !result.conflicts.isEmpty {
            print("\nConflicts resolved: \(result.conflicts.count)")
            for resolved in result.conflicts {
                print("  \(resolved.conflict.path): \(resolved.action)")
            }
        }

        if !result.errors.isEmpty {
            print("\nWarnings: \(result.errors.count)")
            for error in result.errors.prefix(5) {
                print("  \(error.localizedDescription)")
            }
            if result.errors.count > 5 {
                print("  ... and \(result.errors.count - 5) more")
            }
        }

        if dryRun {
            print("\nNo changes were made (dry run mode)")
        }

        // Exit with error if there were any failures during sync
        if !result.errors.isEmpty {
            throw ExitCode(1)
        }
    }

    func parseConflictResolution(_ strategy: String) throws -> ConflictResolution {
        switch strategy.lowercased() {
        case "error", "abort":
            return .error
        case "newest", "newer", "newer-wins":
            return .newest
        case "source", "source-wins":
            return .sourceWins
        case "dest", "dest-wins", "destination-wins":
            return .destinationWins
        default:
            let validStrategies = ["error", "newest", "source-wins", "dest-wins"]
            throw CLIError.invalidFormat(strategy, validFormats: validStrategies)
        }
    }

    func showProgress(_ progress: SyncProgress) {
        if let total = progress.totalFiles {
            let percent = (progress.filesProcessed * 100) / max(total, 1)
            print("  Progress: \(progress.filesProcessed)/\(total) files (\(percent)%) - \(progress.currentOperation)", terminator: "\r")
        } else {
            print("  Progress: \(progress.filesProcessed) files - \(progress.currentOperation)", terminator: "\r")
        }
        fflush(stdout)
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
