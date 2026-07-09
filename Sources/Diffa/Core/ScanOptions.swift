import Foundation

/// Options for scanning directories and creating snapshots
public struct ScanOptions {
    /// Follow symbolic links to their target
    /// Default: true (matches rsync, cp -r behavior)
    /// Note: Will be implemented in Step 4 (Directory Scanning)
    public var followSymlinks: Bool

    /// Include hidden files (files starting with '.')
    /// Default: true (include all files by default)
    /// Note: Will be implemented in Step 4 (Directory Scanning)
    public var includeHidden: Bool

    /// Capture file ownership (owner, group)
    /// Default: false (ownership often not useful across machines)
    /// Note: Requires appropriate permissions to read ownership
    public var captureOwnership: Bool

    /// Enable hash caching for faster subsequent scans
    /// Default: false (opt-in for Phase 4 optimization)
    /// When enabled, file hashes are cached based on size and modification time
    public var useHashCache: Bool

    /// Custom hash cache directory
    /// Default: nil (uses ~/.diffa/cache/)
    /// Each directory gets its own cache database based on path hash
    public var hashCacheDirectory: URL?

    /// Enable parallel hashing (uses multiple CPU cores)
    /// Default: false (opt-in for Phase 4 optimization)
    public var useParallelHashing: Bool

    /// Maximum concurrent hash operations when parallel hashing is enabled
    /// Default: ProcessInfo.activeProcessorCount
    public var maxConcurrentHashing: Int

    /// Names to exclude from the scan (matched against each entry's last
    /// path component). Excluding a directory name skips its entire
    /// subtree — it is never entered. Common use: build/VCS artifacts such
    /// as `.build`, `.git`, `node_modules`.
    /// Default: empty (scan everything).
    public var exclude: Set<String>

    /// Create with default options
    public init(
        followSymlinks: Bool = true,
        includeHidden: Bool = true,
        captureOwnership: Bool = false,
        useHashCache: Bool = false,
        hashCacheDirectory: URL? = nil,
        useParallelHashing: Bool = false,
        maxConcurrentHashing: Int = ProcessInfo.processInfo.activeProcessorCount,
        exclude: Set<String> = []
    ) {
        self.followSymlinks = followSymlinks
        self.includeHidden = includeHidden
        self.captureOwnership = captureOwnership
        self.useHashCache = useHashCache
        self.hashCacheDirectory = hashCacheDirectory
        self.useParallelHashing = useParallelHashing
        self.maxConcurrentHashing = max(1, maxConcurrentHashing)
        self.exclude = exclude
    }
}

// Note: ScanOptions is defined here for Step 4 (Directory Scanning) but is not yet
// fully implemented. Currently only captureOwnership is used by FileSystemItem.
// The scanner (Step 4) will honor followSymlinks and includeHidden.
