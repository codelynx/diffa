import Foundation
import ArgumentParser
import Diffalla

@available(macOS 13.0, *)
struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a directory matches a snapshot"
    )

    @Argument(help: "Directory to verify")
    var directory: String

    @Argument(help: "Snapshot file to verify against")
    var snapshot: String

    @Flag(name: .long, help: "Show differences if verification fails")
    var showDiff: Bool = false

    func run() throws {
        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await performVerify()
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

    func performVerify() async throws {
        // Validate directory exists
        let directoryURL = URL(fileURLWithPath: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalidDirectory(directory)
        }

        // Validate snapshot file exists
        let snapshotURL = URL(fileURLWithPath: snapshot)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw CLIError.snapshotNotFound(snapshot)
        }

        // Load the reference snapshot
        print("Loading snapshot \(snapshot)...")
        let referenceSnapshot = try Snapshot.open(at: snapshotURL)

        // Create temporary snapshot of current directory
        print("Creating snapshot of \(directory)...")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffalla-verify-\(UUID().uuidString).db")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let engine = SnapshotEngine()
        let currentSnapshot = try await engine.createSnapshot(
            from: directoryURL,
            saveTo: tempURL,
            options: ScanOptions()
        )

        // Compare snapshots
        print("Comparing...")
        let difference = try Difference.compare(source: referenceSnapshot, destination: currentSnapshot)

        // Get counts
        let addedCount = try difference.added.count
        let removedCount = try difference.removed.count
        let modifiedCount = try difference.modified.count

        if addedCount == 0 && removedCount == 0 && modifiedCount == 0 {
            // Perfect match
            print("\n" + Colors.success("✓ Verification successful"))
            print("  Directory matches snapshot perfectly")
            // Exit 0
        } else {
            // Differences found
            print("\n" + Colors.error("✗ Verification failed"))
            print("\nDifferences:")
            print("  Added:    \(addedCount) files")
            print("  Removed:  \(removedCount) files")
            print("  Modified: \(modifiedCount) files")

            if showDiff {
                if addedCount > 0 {
                    print("\nAdded files:")
                    for item in try difference.added {
                        print(Colors.success("  + \(item.path)"))
                    }
                }

                if removedCount > 0 {
                    print("\nRemoved files:")
                    for item in try difference.removed {
                        print(Colors.error("  - \(item.path)"))
                    }
                }

                if modifiedCount > 0 {
                    print("\nModified files:")
                    for item in try difference.modified {
                        print(Colors.warning("  * \(item.path)"))
                    }
                }
            } else {
                print("\nUse --show-diff to see detailed differences")
            }

            // Exit 1
            throw ExitCode(1)
        }
    }
}
