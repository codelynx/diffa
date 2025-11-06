import Foundation
import ArgumentParser
import Diffalla

@available(macOS 13.0, *)
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

    @Option(name: .shortAndLong, help: "Output format (text, json)")
    var format: String = "text"

    func run() throws {
        // Validate format option
        let validFormats = ["text", "json"]
        guard validFormats.contains(format.lowercased()) else {
            throw CLIError.invalidFormat(format, validFormats: validFormats)
        }

        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await performComparison()
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

    func performComparison() async throws {
        // Load or create snapshots
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

        // Get counts
        let addedCount = try difference.added.count
        let removedCount = try difference.removed.count
        let modifiedCount = try difference.modified.count

        // Output based on format
        if format == "json" {
            try printJSON(difference: difference, addedCount: addedCount, removedCount: removedCount, modifiedCount: modifiedCount)
        } else {
            try printText(difference: difference, addedCount: addedCount, removedCount: removedCount, modifiedCount: modifiedCount)
        }

        // Exit code: 0 if identical, 1 if different
        if addedCount > 0 || removedCount > 0 || modifiedCount > 0 {
            throw ExitCode(1)
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

    func printText(difference: Difference, addedCount: Int, removedCount: Int, modifiedCount: Int) throws {
        print("\nComparison Results")
        print("==================")
        print("Added:    \(addedCount) files")
        print("Removed:  \(removedCount) files")
        print("Modified: \(modifiedCount) files")

        if !summary && (addedCount > 0 || removedCount > 0 || modifiedCount > 0) {
            if addedCount > 0 {
                print("\nAdded Files:")
                for item in try difference.added {
                    print("  + \(item.path)")
                    if detailed {
                        print("      Size: \(formatBytes(item.size))")
                    }
                }
            }

            if removedCount > 0 {
                print("\nRemoved Files:")
                for item in try difference.removed {
                    print("  - \(item.path)")
                    if detailed {
                        print("      Size: \(formatBytes(item.size))")
                    }
                }
            }

            if modifiedCount > 0 {
                print("\nModified Files:")
                for item in try difference.modified {
                    print("  * \(item.path)")
                    if detailed {
                        print("      Size: \(formatBytes(item.size))")
                    }
                }
            }
        }

        if addedCount == 0 && removedCount == 0 && modifiedCount == 0 {
            print("\n✓ Directories are identical")
        }
    }

    func printJSON(difference: Difference, addedCount: Int, removedCount: Int, modifiedCount: Int) throws {
        var result: [String: Any] = [
            "summary": [
                "added": addedCount,
                "removed": removedCount,
                "modified": modifiedCount
            ]
        ]

        if !summary {
            result["added"] = try difference.added.map { item in
                ["path": item.path, "size": item.size]
            }
            result["removed"] = try difference.removed.map { item in
                ["path": item.path, "size": item.size]
            }
            result["modified"] = try difference.modified.map { item in
                ["path": item.path, "size": item.size]
            }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
