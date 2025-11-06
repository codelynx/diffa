import Foundation
import Crypto

/// Progress information during directory scanning
public struct SnapshotProgress {
    /// Current path being processed
    public let currentPath: String

    /// Number of files processed so far
    public let filesProcessed: Int

    /// Total bytes processed so far
    public let bytesProcessed: Int64

    /// Number of cache hits (hash reused from cache)
    public let cacheHits: Int

    /// Number of cache misses (hash computed and stored)
    public let cacheMisses: Int

    public init(
        currentPath: String,
        filesProcessed: Int,
        bytesProcessed: Int64,
        cacheHits: Int = 0,
        cacheMisses: Int = 0
    ) {
        self.currentPath = currentPath
        self.filesProcessed = filesProcessed
        self.bytesProcessed = bytesProcessed
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
    }
}

/// Engine for scanning directories and creating snapshots
public class SnapshotEngine {
    /// Create a new snapshot engine
    public init() {}

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

        if options.useParallelHashing {
            state.parallelHasher = ParallelHasher(maxConcurrentHashes: options.maxConcurrentHashing)
        }

        try await scanDirectoryRecursive(
            at: url,
            baseURL: url,
            options: options,
            state: state,
            progress: progress
        )

        return state.items
    }

    /// Count files and total size in a directory (fast, no hashing)
    /// - Parameters:
    ///   - url: Root directory URL to count
    ///   - options: Scan options (hidden files, symlinks)
    /// - Returns: Tuple of (file count, total size in bytes)
    public func countFilesAndSize(
        at url: URL,
        options: ScanOptions
    ) throws -> (fileCount: Int, totalSize: Int64) {
        var fileCount = 0
        var totalSize: Int64 = 0

        try countRecursive(
            at: url,
            options: options,
            fileCount: &fileCount,
            totalSize: &totalSize
        )

        return (fileCount, totalSize)
    }

    /// Recursive helper for counting files
    private func countRecursive(
        at url: URL,
        options: ScanOptions,
        fileCount: inout Int,
        totalSize: inout Int64
    ) throws {
        let fileManager = FileManager.default

        // Get directory contents
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        } catch {
            return
        }

        for itemURL in contents {
            guard shouldInclude(itemURL, options: options) else {
                continue
            }

            let resourceValues: URLResourceValues
            do {
                resourceValues = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            } catch {
                continue
            }

            let isSymlink = resourceValues.isSymbolicLink ?? false
            guard let resolvedURL = try resolveURL(for: itemURL, isSymlink: isSymlink, options: options) else {
                continue
            }

            let isDirectory = resourceValues.isDirectory ?? false

            if isDirectory {
                // Recurse into directories
                if !(isSymlink && options.followSymlinks) {
                    try countRecursive(
                        at: resolvedURL,
                        options: options,
                        fileCount: &fileCount,
                        totalSize: &totalSize
                    )
                }
            } else {
                // Count files
                fileCount += 1
                if let size = resourceValues.fileSize {
                    totalSize += Int64(size)
                }
            }
        }
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

            // Initialize hash cache if enabled
            if options.useHashCache {
                state.hashCache = try openOrCreateCache(for: directory, options: options)
            }

            if options.useParallelHashing {
                state.parallelHasher = ParallelHasher(maxConcurrentHashes: options.maxConcurrentHashing)
            }

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

            // Prune cache if enabled (remove entries for deleted files)
            if let cache = state.hashCache {
                // Collect all scanned paths from the database
                let paths = try collectAllPaths(from: snapshot.database)
                try cache.prune(validPaths: Set(paths))
            }

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

    /// Open or create a hash cache for a directory
    /// - Parameters:
    ///   - directory: Directory being scanned
    ///   - options: Scan options containing cache directory preference
    /// - Returns: HashCache instance
    private func openOrCreateCache(for directory: URL, options: ScanOptions) throws -> HashCache {
        // Determine cache directory
        let cacheDir: URL
        if let customDir = options.hashCacheDirectory {
            cacheDir = customDir
        } else {
            // Default: ~/.diffa/cache/
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            cacheDir = homeDir.appendingPathComponent(".diffa/cache")
        }

        // Create cache directory if it doesn't exist
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Generate cache database name from directory path hash
        let directoryPath = directory.path
        let pathHash = directoryPath.data(using: .utf8)!.sha256Hex()
        let cacheURL = cacheDir.appendingPathComponent("\(pathHash).db")

        // Open or create cache
        return try HashCache(at: cacheURL)
    }

    /// Collect all file paths from snapshot database for cache pruning
    /// - Parameter database: Snapshot database
    /// - Returns: Array of all file paths
    private func collectAllPaths(from database: SQLiteDatabase) throws -> [String] {
        let sql = "SELECT path FROM items WHERE is_folder = 0"
        let statement = try database.prepare(sql)
        let rows = try statement.query()

        var paths: [String] = []
        for row in rows {
            guard let path = try row.string(at: 0) else { continue }
            paths.append(path)
        }
        return paths
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
        var cacheHits: Int = 0
        var cacheMisses: Int = 0

        // Optional writer for streaming to database
        weak var writer: SnapshotWriter?

        // Optional hash cache for reusing hashes
        var hashCache: HashCache?

        // Optional parallel hasher (limits concurrent hash computations)
        var parallelHasher: ParallelHasher?
    }

    private struct ParallelFileResult {
        let item: FileSystemItem
        let cacheHit: Bool?
        let resolvedURL: URL
        let isSymlink: Bool
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

        if let parallelHasher = state.parallelHasher {
            try await processDirectoryContentsParallel(
                contents: contents,
                baseURL: baseURL,
                options: options,
                state: state,
                progress: progress,
                parallelHasher: parallelHasher
            )
        } else {
            try await processDirectoryContentsSequential(
                contents: contents,
                baseURL: baseURL,
                options: options,
                state: state,
                progress: progress
            )
        }
    }

    private func processDirectoryContentsSequential(
        contents: [URL],
        baseURL: URL,
        options: ScanOptions,
        state: ScanState,
        progress: ((SnapshotProgress) -> Void)?
    ) async throws {
        for itemURL in contents {
            guard shouldInclude(itemURL, options: options) else {
                continue
            }

            let resourceValues: URLResourceValues
            do {
                resourceValues = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                continue
            }

            let isSymlink = resourceValues.isSymbolicLink ?? false

            guard let resolvedURL = try resolveURL(for: itemURL, isSymlink: isSymlink, options: options) else {
                continue
            }

            do {
                let item = try await createFileSystemItem(
                    resolvedURL: resolvedURL,
                    originalURL: itemURL,
                    baseURL: baseURL,
                    options: options,
                    isSymlink: isSymlink,
                    hashCache: state.hashCache,
                    parallelHasher: nil,
                    cacheStatsCallback: { isHit in
                        if isHit {
                            state.cacheHits += 1
                        } else {
                            state.cacheMisses += 1
                        }
                    }
                )

                try await finalize(
                    item: item,
                    isSymlink: isSymlink,
                    resolvedURL: resolvedURL,
                    baseURL: baseURL,
                    options: options,
                    state: state,
                    progress: progress
                )
            } catch {
                continue
            }
        }
    }

    private func processDirectoryContentsParallel(
        contents: [URL],
        baseURL: URL,
        options: ScanOptions,
        state: ScanState,
        progress: ((SnapshotProgress) -> Void)?,
        parallelHasher: ParallelHasher
    ) async throws {
        let hashCache = state.hashCache

        try await withThrowingTaskGroup(of: ParallelFileResult?.self) { group in
            var pendingTasks = 0

            for itemURL in contents {
                guard shouldInclude(itemURL, options: options) else {
                    continue
                }

                let resourceValues: URLResourceValues
                do {
                    resourceValues = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                } catch {
                    continue
                }

                let isSymlink = resourceValues.isSymbolicLink ?? false
                guard let resolvedURL = try resolveURL(for: itemURL, isSymlink: isSymlink, options: options) else {
                    continue
                }

                let isDirectory = resourceValues.isDirectory ?? false
                let shouldParallelize = !isDirectory && !isSymlink

                if shouldParallelize {
                    pendingTasks += 1
                    group.addTask {
                        do {
                            var cacheHit: Bool?
                            let item = try await self.createFileSystemItem(
                                resolvedURL: resolvedURL,
                                originalURL: itemURL,
                                baseURL: baseURL,
                                options: options,
                                isSymlink: isSymlink,
                                hashCache: hashCache,
                                parallelHasher: parallelHasher,
                                cacheStatsCallback: { cacheHit = $0 }
                            )
                            return ParallelFileResult(
                                item: item,
                                cacheHit: cacheHit,
                                resolvedURL: resolvedURL,
                                isSymlink: isSymlink
                            )
                        } catch {
                            return nil
                        }
                    }
                } else {
                    do {
                        let item = try await createFileSystemItem(
                            resolvedURL: resolvedURL,
                            originalURL: itemURL,
                            baseURL: baseURL,
                            options: options,
                            isSymlink: isSymlink,
                            hashCache: state.hashCache,
                            parallelHasher: nil,
                            cacheStatsCallback: { isHit in
                                if isHit {
                                    state.cacheHits += 1
                                } else {
                                    state.cacheMisses += 1
                                }
                            }
                        )

                        try await finalize(
                            item: item,
                            isSymlink: isSymlink,
                            resolvedURL: resolvedURL,
                            baseURL: baseURL,
                            options: options,
                            state: state,
                            progress: progress
                        )
                    } catch {
                        continue
                    }
                }
            }

            while pendingTasks > 0 {
                guard let taskResult = try await group.next() else {
                    pendingTasks = 0
                    break
                }
                pendingTasks -= 1

                guard let parallelResult = taskResult else {
                    continue
                }

                if let cacheHit = parallelResult.cacheHit {
                    if cacheHit {
                        state.cacheHits += 1
                    } else {
                        state.cacheMisses += 1
                    }
                }

                try await finalize(
                    item: parallelResult.item,
                    isSymlink: parallelResult.isSymlink,
                    resolvedURL: parallelResult.resolvedURL,
                    baseURL: baseURL,
                    options: options,
                    state: state,
                    progress: progress
                )
            }
        }
    }

    private func createFileSystemItem(
        resolvedURL: URL,
        originalURL: URL,
        baseURL: URL,
        options: ScanOptions,
        isSymlink: Bool,
        hashCache: HashCache?,
        parallelHasher: ParallelHasher?,
        cacheStatsCallback: ((Bool) -> Void)?
    ) async throws -> FileSystemItem {
        if isSymlink && options.followSymlinks {
            return try await FileSystemItem(
                at: resolvedURL,
                relativeTo: baseURL,
                captureOwnership: options.captureOwnership,
                pathOverride: originalURL,
                followSymlinks: true,
                hashCache: hashCache,
                cacheStatsCallback: cacheStatsCallback,
                parallelHasher: parallelHasher
            )
        } else if isSymlink && !options.followSymlinks {
            return try await FileSystemItem(
                at: originalURL,
                relativeTo: baseURL,
                captureOwnership: options.captureOwnership,
                followSymlinks: false,
                hashCache: hashCache,
                cacheStatsCallback: cacheStatsCallback,
                parallelHasher: parallelHasher
            )
        } else {
            return try await FileSystemItem(
                at: resolvedURL,
                relativeTo: baseURL,
                captureOwnership: options.captureOwnership,
                followSymlinks: true,
                hashCache: hashCache,
                cacheStatsCallback: cacheStatsCallback,
                parallelHasher: parallelHasher
            )
        }
    }

    private func finalize(
        item: FileSystemItem,
        isSymlink: Bool,
        resolvedURL: URL,
        baseURL: URL,
        options: ScanOptions,
        state: ScanState,
        progress: ((SnapshotProgress) -> Void)?
    ) async throws {
        if let writer = state.writer {
            let parentPath = computeParentPath(from: item.path)
            let itemId = try writer.insertItem(item, parentPath: parentPath)

            if item.isFolder {
                state.totalFolders += 1
                if !(isSymlink && options.followSymlinks) {
                    writer.pushDirectory(path: item.path, id: itemId)
                }
            } else {
                state.totalFiles += 1
            }

            state.totalSize += item.size
        } else {
            state.items.append(item)
        }

        if !item.isFolder {
            state.filesProcessed += 1
            state.bytesProcessed += item.size
        }

        if let progress = progress {
            let progressInfo = SnapshotProgress(
                currentPath: item.path,
                filesProcessed: state.filesProcessed,
                bytesProcessed: state.bytesProcessed,
                cacheHits: state.cacheHits,
                cacheMisses: state.cacheMisses
            )
            progress(progressInfo)
        }

        if item.isFolder && !(isSymlink && options.followSymlinks) {
            try await scanDirectoryRecursive(
                at: resolvedURL,
                baseURL: baseURL,
                options: options,
                state: state,
                progress: progress
            )

            if let writer = state.writer {
                writer.popDirectory()
            }
        }
    }

    private func resolveURL(for itemURL: URL, isSymlink: Bool, options: ScanOptions) throws -> URL? {
        if isSymlink {
            if options.followSymlinks {
                return try handleSymlink(itemURL, options: options)
            } else {
                return itemURL
            }
        } else {
            return itemURL
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

// MARK: - Data Extension for Hash Cache

extension Data {
    /// Compute SHA-256 hash and return as hex string
    func sha256Hex() -> String {
        let hash = SHA256.hash(data: self)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
