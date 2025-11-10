import Foundation

/// Represents a file with its content hash and metadata
///
/// FileItem is the fundamental unit in EfficientSync. Files are identified
/// by their content (MD5 hash + size) rather than path, enabling:
/// - Content-addressable deduplication
/// - Move detection (same hash, different path)
/// - Zero-copy transfers for duplicate content
///
/// Example:
/// ```swift
/// let file = FileItem(
///     path: "photos/vacation.jpg",
///     size: 2048576,
///     hash: Data(...),  // MD5 (16 bytes)
///     mtime: 1699459200,
///     mode: 0o644
/// )
/// ```
public struct FileItem: Equatable, Codable {
    /// Relative path from snapshot root
    public let path: String

    /// File size in bytes
    public let size: Int64

    /// MD5 hash of file content (16 bytes / 128 bits)
    public let hash: Data

    /// Modification time (Unix timestamp in seconds)
    public let mtime: Int64

    /// POSIX permissions (optional, e.g., 0o644, 0o755)
    /// Nil if not supported by filesystem
    public let mode: UInt16?

    public init(
        path: String,
        size: Int64,
        hash: Data,
        mtime: Int64,
        mode: UInt16? = nil
    ) {
        self.path = path
        self.size = size
        self.hash = hash
        self.mtime = mtime
        self.mode = mode
    }
}

// MARK: - CustomStringConvertible

extension FileItem: CustomStringConvertible {
    public var description: String {
        let hashHex = hash.map { String(format: "%02x", $0) }.joined().prefix(8)
        let modeStr = mode.map { String(format: "0o%o", $0) } ?? "nil"
        return "FileItem(path: \(path), size: \(size), hash: \(hashHex)..., mode: \(modeStr))"
    }
}
