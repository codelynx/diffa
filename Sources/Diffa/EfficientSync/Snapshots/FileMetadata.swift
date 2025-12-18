import Foundation

/// File metadata captured during directory scanning
///
/// Contains essential file information needed for snapshot creation,
/// excluding the content hash (which is computed separately).
///
/// **Design:**
/// - Lightweight: Only stores metadata, not file content
/// - Path: Relative to snapshot root for portability
/// - Timestamps: Unix epoch seconds for cross-platform compatibility
/// - Mode: Optional POSIX permissions (nil on filesystems that don't support it)
///
/// **Example:**
/// ```swift
/// let metadata = FileMetadata(
///     path: "documents/report.pdf",
///     size: 2048576,
///     mtime: 1699459200,
///     mode: 0o644
/// )
/// ```
public struct FileMetadata: Equatable {
    /// Relative path from snapshot root
    public let path: String

    /// File size in bytes
    public let size: Int64

    /// Modification time (Unix timestamp in seconds)
    public let mtime: Int64

    /// POSIX permissions (optional, e.g., 0o644, 0o755)
    /// Nil if filesystem doesn't support permissions
    public let mode: UInt16?

    public init(
        path: String,
        size: Int64,
        mtime: Int64,
        mode: UInt16? = nil
    ) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.mode = mode
    }
}

// MARK: - CustomStringConvertible

extension FileMetadata: CustomStringConvertible {
    public var description: String {
        let modeStr = mode.map { String(format: "0o%o", $0) } ?? "nil"
        return "FileMetadata(path: \(path), size: \(size), mtime: \(mtime), mode: \(modeStr))"
    }
}
