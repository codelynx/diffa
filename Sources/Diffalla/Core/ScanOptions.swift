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

    /// Create with default options
    public init(
        followSymlinks: Bool = true,
        includeHidden: Bool = true,
        captureOwnership: Bool = false
    ) {
        self.followSymlinks = followSymlinks
        self.includeHidden = includeHidden
        self.captureOwnership = captureOwnership
    }
}

// Note: ScanOptions is defined here for Step 4 (Directory Scanning) but is not yet
// fully implemented. Currently only captureOwnership is used by FileSystemItem.
// The scanner (Step 4) will honor followSymlinks and includeHidden.
