import Foundation
import ArgumentParser
import Diffalla

fileprivate func formatPatchOperation(_ operation: PatchOperation, isRevert: Bool) -> String {
    if isRevert {
        switch operation {
        case .add(let path, _):
            return "[REMOVE] \(path)"
        case .remove(let path, _):
            return "[RESTORE] \(path)"
        case .modify(let path, _):
            return "[RESTORE] \(path)"
        case .move(let from, let to, _):
            return "[MOVE] \(to) -> \(from)"
        }
    } else {
        switch operation {
        case .add(let path, _):
            return "[ADD] \(path)"
        case .remove(let path, _):
            return "[REMOVE] \(path)"
        case .modify(let path, _):
            return "[MODIFY] \(path)"
        case .move(let from, let to, _):
            return "[MOVE] \(from) -> \(to)"
        }
    }
}

@available(macOS 13.0, *)
struct PatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch",
        abstract: "Create, apply, or revert patches",
        subcommands: [
            CreatePatch.self,
            ApplyPatch.self,
            RevertPatch.self
        ]
    )
}

// MARK: - Patch Create

@available(macOS 13.0, *)
struct CreatePatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a patch from a comparison"
    )

    @Argument(help: "Source snapshot or directory")
    var source: String

    @Argument(help: "Destination snapshot or directory")
    var destination: String

    @Option(name: .shortAndLong, help: "Output patch file path")
    var output: String

    @Flag(name: .long, help: "Include file content (create reversible patch)")
    var reversible: Bool = false

    func run() throws {
        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await createPatch()
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

    func createPatch() async throws {
        // Get URLs for source and destination
        let sourceURL = URL(fileURLWithPath: source)
        let destURL = URL(fileURLWithPath: destination)

        // Load or create snapshots
        print("Creating patch from \(source) to \(destination)...")
        let sourceSnapshot = try await loadOrCreateSnapshot(path: source, label: "source")
        let destSnapshot = try await loadOrCreateSnapshot(path: destination, label: "destination")

        // Clean up temporary snapshots
        defer {
            if !isSnapshotFile(source) {
                try? FileManager.default.removeItem(at: sourceSnapshot.databaseURL)
            }
            if !isSnapshotFile(destination) {
                try? FileManager.default.removeItem(at: destSnapshot.databaseURL)
            }
        }

        // Perform comparison
        let difference = try Difference.compare(source: sourceSnapshot, destination: destSnapshot)

        // Check if there are any changes
        let addedCount = try difference.added.count
        let removedCount = try difference.removed.count
        let modifiedCount = try difference.modified.count

        if addedCount == 0 && removedCount == 0 && modifiedCount == 0 {
            print("No differences found - patch not created")
            return
        }

        // Create patch
        let outputURL = URL(fileURLWithPath: output)
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: sourceURL,
            destinationDirectory: destURL,
            saveTo: outputURL,
            includeRevertData: reversible
        )

        // Print summary
        print("\n" + Colors.success("✓ Patch created successfully"))
        print("  Output: \(output)")
        print("  Operations: \(patch.metadata.operationCount)")
        print("    Added: \(addedCount)")
        print("    Removed: \(removedCount)")
        print("    Modified: \(modifiedCount)")
        if reversible {
            print("  Reversible: Yes")
        }
    }

    func loadOrCreateSnapshot(path: String, label: String) async throws -> Snapshot {
        if isSnapshotFile(path) {
            // Load existing snapshot
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.snapshotNotFound(path)
            }
            return try Snapshot.open(at: url)
        } else {
            // Create temporary snapshot from directory
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CLIError.invalidDirectory(path)
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("diffalla-\(label)-\(UUID().uuidString).db")

            print("Creating temporary snapshot for \(label)...")
            let engine = SnapshotEngine()
            let options = ScanOptions()
            return try await engine.createSnapshot(from: url, saveTo: tempURL, options: options)
        }
    }

    func isSnapshotFile(_ path: String) -> Bool {
        return path.hasSuffix(".db") || path.hasSuffix(".sqlite")
    }
}

// MARK: - Patch Apply

@available(macOS 13.0, *)
struct ApplyPatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a patch to a directory"
    )

    @Argument(help: "Patch file to apply")
    var patch: String

    @Argument(help: "Target directory")
    var directory: String

    @Flag(name: .long, help: "Dry run (show what would be changed without applying)")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Force apply even if validation fails")
    var force: Bool = false

    func run() throws {
        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await applyPatch()
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

    func applyPatch() async throws {
        // Validate patch file exists
        let patchURL = URL(fileURLWithPath: patch)
        guard FileManager.default.fileExists(atPath: patchURL.path) else {
            throw CLIError.patchNotFound(patch)
        }

        // Validate target directory exists
        let directoryURL = URL(fileURLWithPath: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalidDirectory(directory)
        }

        // Load patch
        print("Loading patch from \(patch)...")
        let patchObj = try Patch.open(at: patchURL)

        // Get operation counts
        let operations = try patchObj.loadOperations()
        print("Patch contains \(operations.count) operations")

        if dryRun {
            // Dry run: show what would be done
            print("\n--- Dry Run Mode (no changes will be made) ---\n")
            var addCount = 0, removeCount = 0, modifyCount = 0, moveCount = 0

            for operation in operations {
                switch operation {
                case .add(let path, _):
                    print("  [ADD]    \(path)")
                    addCount += 1
                case .remove(let path, _):
                    print("  [REMOVE] \(path)")
                    removeCount += 1
                case .modify(let path, _):
                    print("  [MODIFY] \(path)")
                    modifyCount += 1
                case .move(let from, let to, _):
                    print("  [MOVE]   \(from) -> \(to)")
                    moveCount += 1
                }
            }

            print("\nSummary:")
            print("  Add:    \(addCount)")
            print("  Remove: \(removeCount)")
            print("  Modify: \(modifyCount)")
            print("  Move:   \(moveCount)")
            print("\nUse without --dry-run to apply these changes")
        } else {
            // Actually apply the patch
            print("Applying patch to \(directory)...")
            print("  Processing \(operations.count) operations...")

            try await patchObj.apply(to: directoryURL, progress: { progress in
                let text = formatPatchOperation(progress.operation, isRevert: progress.isRevert)
                print("  \(progress.current)/\(progress.total) - \(text)", terminator: "\r")
            })

            print("\n" + Colors.success("✓ Patch applied successfully"))
            print("  Operations applied: \(operations.count)")
        }
    }
}

// MARK: - Patch Revert

@available(macOS 13.0, *)
struct RevertPatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revert",
        abstract: "Revert a previously applied patch"
    )

    @Argument(help: "Patch file to revert")
    var patch: String

    @Argument(help: "Target directory")
    var directory: String

    @Flag(name: .long, help: "Dry run (show what would be changed without reverting)")
    var dryRun: Bool = false

    func run() throws {
        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await revertPatch()
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

    func revertPatch() async throws {
        // Validate patch file exists
        let patchURL = URL(fileURLWithPath: patch)
        guard FileManager.default.fileExists(atPath: patchURL.path) else {
            throw CLIError.patchNotFound(patch)
        }

        // Validate target directory exists
        let directoryURL = URL(fileURLWithPath: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalidDirectory(directory)
        }

        // Load patch
        print("Loading patch from \(patch)...")
        let patchObj = try Patch.open(at: patchURL)

        // Check if patch is reversible
        let hasRevert = try patchObj.hasRevertData()
        if !hasRevert {
            print(Colors.error("Error: This patch is not reversible (no revert data stored)"))
            print("Patches must be created with --reversible flag to be revertable")
            throw ExitCode(1)
        }

        // Get operation counts
        let operations = try patchObj.loadOperations()
        print("Patch contains \(operations.count) operations")

        if dryRun {
            // Dry run: show what would be done
            print("\n--- Dry Run Mode (no changes will be made) ---\n")
            var addCount = 0, removeCount = 0, modifyCount = 0, moveCount = 0

            for operation in operations {
                switch operation {
                case .add(let path, _):
                    // Reverting add = remove
                    print("  [REMOVE] \(path)")
                    removeCount += 1
                case .remove(let path, _):
                    // Reverting remove = restore
                    print("  [RESTORE] \(path)")
                    addCount += 1
                case .modify(let path, _):
                    // Reverting modify = restore old content
                    print("  [RESTORE] \(path)")
                    modifyCount += 1
                case .move(let from, let to, _):
                    // Reverting move = move back
                    print("  [MOVE]   \(to) -> \(from)")
                    moveCount += 1
                }
            }

            print("\nSummary:")
            print("  Restore: \(addCount)")
            print("  Remove:  \(removeCount)")
            print("  Revert:  \(modifyCount)")
            print("  Move:    \(moveCount)")
            print("\nUse without --dry-run to revert these changes")
        } else {
            // Actually revert the patch
            print("Reverting patch on \(directory)...")
            print("  Processing \(operations.count) operations...")

            try await patchObj.revert(on: directoryURL, progress: { progress in
                let text = formatPatchOperation(progress.operation, isRevert: progress.isRevert)
                print("  \(progress.current)/\(progress.total) - \(text)", terminator: "\r")
            })

            print("\n" + Colors.success("✓ Patch reverted successfully"))
            print("  Operations reverted: \(operations.count)")
        }
    }
}
