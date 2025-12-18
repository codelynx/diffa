import Foundation
import ArgumentParser
import Diffa

@available(macOS 13.0, *)
struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Create a snapshot of a directory"
    )

    @Argument(help: "Directory to snapshot")
    var directory: String

    @Option(name: .shortAndLong, help: "Output snapshot file path")
    var output: String?

    @Flag(name: .long, help: "Follow symbolic links")
    var followSymlinks: Bool = false

    @Option(name: .long, help: "Exclude pattern (can be repeated)")
    var exclude: [String] = []

    @Flag(name: .long, help: "Enable hash caching for faster subsequent scans")
    var useCache: Bool = false

    @Flag(name: .long, help: "Enable parallel hashing (faster on multi-core systems)")
    var parallel: Bool = false

    func run() throws {
        try runAsync()
    }

    func runAsync() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?

        Task {
            do {
                try await createSnapshot()
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

    func createSnapshot() async throws {
        // Validate and convert directory path to URL
        let directoryURL = URL(fileURLWithPath: directory)

        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalidDirectory(directory)
        }

        // Generate output path if not provided
        let outputPath: String
        if let output = output {
            outputPath = output
        } else {
            let dirName = directoryURL.lastPathComponent
            outputPath = "\(dirName).diffa"
        }
        let outputURL = URL(fileURLWithPath: outputPath)

        // Create scan options
        let options = ScanOptions(
            followSymlinks: followSymlinks,
            includeHidden: true,  // Always include hidden files
            captureOwnership: false,
            useHashCache: useCache,
            hashCacheDirectory: nil,
            useParallelHashing: parallel
        )

        // Create snapshot with progress
        print("Creating snapshot of \(directory)...")
        if !exclude.isEmpty {
            print("Note: Exclude patterns not yet supported (coming soon)")
        }

        let engine = SnapshotEngine()

        // First pass: Count files (fast)
        print("Counting files...", terminator: "")
        fflush(stdout)
        let (totalFiles, totalSize) = try engine.countFilesAndSize(at: directoryURL, options: options)
        print("\r\u{1B}[K", terminator: "") // Clear the counting line
        fflush(stdout)

        // Second pass: Create snapshot with progress
        var lastProgress = Date()

        let snapshot = try await engine.createSnapshot(
            from: directoryURL,
            saveTo: outputURL,
            options: options,
            progress: { progress in
                // Update progress every 0.5 seconds
                let now = Date()
                if now.timeIntervalSince(lastProgress) >= 0.5 {
                    let currentSizeStr = Self.formatBytes(progress.bytesProcessed)
                    let totalSizeStr = Self.formatBytes(totalSize)
                    let fileName = (progress.currentPath as NSString).lastPathComponent
                    print("  Processing: \(progress.filesProcessed)/\(totalFiles) files (\(currentSizeStr) / \(totalSizeStr)) - \(fileName)", terminator: "\r")
                    fflush(stdout)
                    lastProgress = now
                }
            }
        )

        // Clear progress line and show summary
        print("\n")
        print(Colors.success("✓ Snapshot created successfully"))
        print("  Output: \(outputPath)")
        print("  Files: \(snapshot.metadata.totalFiles)")
        print("  Directories: \(snapshot.metadata.totalFolders)")
        print("  Total size: \(Self.formatBytes(snapshot.metadata.totalSize))")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

enum CLIError: LocalizedError {
    case invalidDirectory(String)
    case snapshotNotFound(String)
    case patchNotFound(String)
    case invalidFormat(String, validFormats: [String])

    var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path):
            return "Directory not found or not accessible: \(path)"
        case .snapshotNotFound(let path):
            return "Snapshot file not found: \(path)"
        case .patchNotFound(let path):
            return "Patch file not found: \(path)"
        case .invalidFormat(let format, let validFormats):
            return "Invalid format '\(format)'. Valid formats: \(validFormats.joined(separator: ", "))"
        }
    }
}
