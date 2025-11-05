import Foundation

/// Protocol for items that can be compared (files and folders)
public protocol ItemProtocol: Equatable {
    /// Relative path from snapshot root
    var path: String { get }

    /// True if this is a directory, false for files
    var isFolder: Bool { get }

    /// SHA-256 hash of file content (nil for folders)
    var sha256: String? { get }

    /// Size in bytes (file size or total size for folders)
    var size: Int64 { get }

    /// File system metadata
    var metadata: Metadata { get }
}
