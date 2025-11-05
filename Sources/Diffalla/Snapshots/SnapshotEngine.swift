import Foundation

/// Progress information during directory scanning
public struct SnapshotProgress {
    /// Current path being processed
    public let currentPath: String

    /// Number of files processed so far
    public let filesProcessed: Int

    /// Total bytes processed so far
    public let bytesProcessed: Int64

    public init(currentPath: String, filesProcessed: Int, bytesProcessed: Int64) {
        self.currentPath = currentPath
        self.filesProcessed = filesProcessed
        self.bytesProcessed = bytesProcessed
    }
}

/// Engine for scanning directories and creating snapshots
public class SnapshotEngine {
    /// Recursively scan a directory and collect all items
    /// - Parameters:
    ///   - url: Root directory URL to scan
    ///   - options: Scan options (hidden files, symlinks, ownership)
    ///   - progress: Optional progress callback
    /// - Returns: Array of FileSystemItems representing the directory tree
    public func scanDirectory(
        at url: URL,
        options: ScanOptions,
        progress: ((SnapshotProgress) -> Void)? = nil
    ) async throws -> [FileSystemItem] {
        // Use a class to hold mutable state (avoiding inout with async)
        let state = ScanState()

        try await scanDirectoryRecursive(
            at: url,
            baseURL: url,
            options: options,
            state: state,
            progress: progress
        )

        return state.items
    }

    /// Create a snapshot from a directory
    /// - Parameters:
    ///   - directory: Root directory to snapshot
    ///   - snapshotURL: URL where snapshot database should be saved
    ///   - options: Scan options (hidden files, symlinks, ownership)
    ///   - progress: Optional progress callback
    /// - Returns: The created Snapshot
    public func createSnapshot(
        from directory: URL,
        saveTo snapshotURL: URL,
        options: ScanOptions,
        progress: ((SnapshotProgress) -> Void)? = nil
    ) async throws -> Snapshot {
        // Create a new snapshot database
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: directory.path)

        // Stream items to database during scan (memory-efficient)
        // Manual transaction management since scanDirectoryRecursive is async
        try snapshot.database.execute("BEGIN TRANSACTION")

        do {
            let writer = SnapshotWriter(database: snapshot.database)
            let state = ScanState()
            state.writer = writer  // Enable streaming mode

            // Scan directory - items are written to DB as discovered
            try await scanDirectoryRecursive(
                at: directory,
                baseURL: directory,
                options: options,
                state: state,
                progress: progress
            )

            // Update metadata with totals
            try writer.updateMetadata(
                totalFiles: state.totalFiles,
                totalFolders: state.totalFolders,
                totalSize: state.totalSize
            )

            try snapshot.database.execute("COMMIT")
        } catch {
            try? snapshot.database.execute("ROLLBACK")
            throw error
        }

        // Re-open the snapshot to get updated metadata
        // The Snapshot struct returned by create() has stale metadata (all zeros)
        // so we must reload it from the database to get the actual counts
        return try Snapshot.open(at: snapshotURL)
    }

    /// Compute parent path from a full path
    /// - Parameter path: The full relative path (e.g., "dir/subdir/file.txt")
    /// - Returns: Parent path (e.g., "dir/subdir"), or nil if root level
    private func computeParentPath(from path: String) -> String? {
        // If path has no slashes, it's a root-level item (no parent)
        guard path.contains("/") else {
            return nil
        }

        // Remove last component to get parent path
        let components = path.split(separator: "/")
        guard components.count > 1 else {
            return nil
        }

        return components.dropLast().joined(separator: "/")
    }

    /// Internal state for scanning (avoiding inout with async)
    private class ScanState {
        var items: [FileSystemItem] = []
        var filesProcessed: Int = 0
        var bytesProcessed: Int64 = 0
        var totalFiles: Int = 0
        var totalFolders: Int = 0
        var totalSize: Int64 = 0

        // Optional writer for streaming to database
        weak var writer: SnapshotWriter?
    }

    /// Recursive helper for directory scanning
    private func scanDirectoryRecursive(
        at url: URL,
        baseURL: URL,
        options: ScanOptions,
        state: ScanState,
        progress: ((SnapshotProgress) -> Void)?
    ) async throws {
        let fileManager = FileManager.default

        // Get directory contents
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [] // Don't skip any files here - we'll filter manually
            )
        } catch {
            // If we can't read the directory (permission denied, etc.), skip it
            return
        }

        // Process each item in the directory
        for itemURL in contents {
            // Check if we should include this item
            guard shouldInclude(itemURL, options: options) else {
                continue
            }

            // Handle symlinks
            let resolvedURL: URL

            // Check if this is a symlink (safely)
            let isSymlink: Bool
            do {
                let resourceValues = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                isSymlink = resourceValues.isSymbolicLink ?? false
            } catch {
                // If we can't read resource values, skip this item
                continue
            }

            if isSymlink {
                if options.followSymlinks {
                    // Follow the symlink
                    do {
                        guard let target = try handleSymlink(itemURL, options: options) else {
                            // Broken symlink - skip it
                            continue
                        }

                        resolvedURL = target
                    } catch {
                        // Error handling symlink - skip it
                        continue
                    }
                } else {
                    // Don't follow symlinks - use the symlink itself
                    resolvedURL = itemURL
                }
            } else {
                resolvedURL = itemURL
            }

            // Create FileSystemItem for this item
            // Note: For symlinks, we read from resolvedURL but compute path from itemURL
            // This ensures symlinks are recorded with their symlink path, not target path
            let item: FileSystemItem
            do {
                if isSymlink && options.followSymlinks {
                    // Read attributes from target, but use symlink path
                    item = try FileSystemItem(
                        at: resolvedURL,
                        relativeTo: baseURL,
                        captureOwnership: options.captureOwnership,
                        pathOverride: itemURL,
                        followSymlinks: true
                    )
                } else if isSymlink && !options.followSymlinks {
                    // Read symlink itself (not target)
                    item = try FileSystemItem(
                        at: itemURL,
                        relativeTo: baseURL,
                        captureOwnership: options.captureOwnership,
                        followSymlinks: false
                    )
                } else {
                    // Normal file or directory
                    item = try FileSystemItem(
                        at: resolvedURL,
                        relativeTo: baseURL,
                        captureOwnership: options.captureOwnership,
                        followSymlinks: true
                    )
                }
            } catch {
                // If we can't read this item (permission denied, etc.), skip it
                continue
            }

            // If writer is present, stream to database immediately
            // Otherwise, collect in memory
            if let writer = state.writer {
                // Compute parent path
                let parentPath = computeParentPath(from: item.path)

                // Insert into database
                let itemId = try writer.insertItem(item, parentPath: parentPath)

                // Update totals for final metadata update
                if item.isFolder {
                    state.totalFolders += 1
                } else {
                    state.totalFiles += 1
                }
                state.totalSize += item.size

                // If this is a directory, push it onto stack before recursing
                if item.isFolder && !(isSymlink && options.followSymlinks) {
                    writer.pushDirectory(path: item.path, id: itemId)
                }
            } else {
                // Collect items in memory for later processing
                state.items.append(item)
            }

            // Update progress
            if !item.isFolder {
                state.filesProcessed += 1
                state.bytesProcessed += item.size
            }

            // Report progress
            if let progress = progress {
                let progressInfo = SnapshotProgress(
                    currentPath: item.path,
                    filesProcessed: state.filesProcessed,
                    bytesProcessed: state.bytesProcessed
                )
                progress(progressInfo)
            }

            // If this is a directory, recursively scan it
            // However, if this is a symlinked directory and we're following symlinks,
            // don't recurse - we'll scan the actual target directory when we encounter it
            if item.isFolder && !(isSymlink && options.followSymlinks) {
                try await scanDirectoryRecursive(
                    at: resolvedURL,
                    baseURL: baseURL,
                    options: options,
                    state: state,
                    progress: progress
                )

                // Pop directory from stack after recursing
                if let writer = state.writer {
                    writer.popDirectory()
                }
            }
        }
    }

    /// Determine if a URL should be included in the scan
    /// - Parameters:
    ///   - url: URL to check
    ///   - options: Scan options
    /// - Returns: True if the item should be included
    private func shouldInclude(_ url: URL, options: ScanOptions) -> Bool {
        let fileName = url.lastPathComponent

        // Check if hidden file
        if !options.includeHidden && fileName.hasPrefix(".") {
            return false
        }

        return true
    }

    /// Handle a symlink by resolving it to its target
    /// - Parameters:
    ///   - url: Symlink URL
    ///   - options: Scan options
    /// - Returns: Target URL, or nil if broken symlink
    private func handleSymlink(_ url: URL, options: ScanOptions) throws -> URL? {
        let fileManager = FileManager.default

        // Get the destination path
        let destinationPath = try fileManager.destinationOfSymbolicLink(atPath: url.path)

        // Resolve to absolute path
        let destinationURL: URL
        if destinationPath.hasPrefix("/") {
            // Absolute path
            destinationURL = URL(fileURLWithPath: destinationPath)
        } else {
            // Relative path - resolve relative to symlink's directory
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destinationPath)
        }

        // Check if target exists
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return nil // Broken symlink
        }

        return destinationURL
    }
}
