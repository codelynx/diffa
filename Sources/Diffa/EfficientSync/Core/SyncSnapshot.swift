import Foundation

/// Protocol for directory snapshots (EfficientSync implementation)
///
/// A SyncSnapshot represents the state of a directory at a point in time.
/// Snapshots are typically backed by SQLite for memory efficiency.
///
/// Example usage:
/// ```swift
/// let snapshot = try SQLiteSnapshot.create(at: URL(fileURLWithPath: "/path/to/dir"))
///
/// // Query by path
/// if let file = snapshot.fileByPath("photos/vacation.jpg") {
///     print("Found: \(file)")
/// }
///
/// // Query by hash (for move detection)
/// let duplicates = snapshot.filesByHash(someHash)
/// print("Files with same content: \(duplicates.count)")
///
/// // Get all files (sorted for determinism)
/// for file in snapshot.allFiles() {
///     print(file.path)
/// }
/// ```
public protocol SyncSnapshot {
    /// Query file by path
    ///
    /// - Parameter path: Relative path from snapshot root
    /// - Returns: FileItem if found, nil otherwise
    func fileByPath(_ path: String) -> FileItem?

    /// Query files by content hash
    ///
    /// Used for:
    /// - Move detection: Find files with same hash at different paths
    /// - Deduplication: Check if content already exists
    ///
    /// - Parameter hash: MD5 hash (16 bytes)
    /// - Returns: Array of FileItems with matching hash (may be empty)
    func filesByHash(_ hash: Data) -> [FileItem]

    /// Get all files in snapshot
    ///
    /// Files are sorted by path for deterministic iteration.
    /// This ensures consistent behavior across runs.
    ///
    /// Note: For large snapshots (100k+ files), this loads all
    /// file metadata into memory (~20MB for 100k files).
    ///
    /// - Returns: Array of all FileItems, sorted by path
    func allFiles() -> [FileItem]
}
