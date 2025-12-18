import Foundation

/// Represents a synchronization operation to perform
///
/// FileOperation describes what needs to be done to synchronize files
/// between source and destination. It stores complete metadata for both
/// sides to enable all conflict resolution strategies.
///
/// **Dual-File Model:**
/// - `localFile`: Destination/client version (may be nil for additions)
/// - `remoteFile`: Source/server version (may be nil for deletions)
///
/// **Convenience Accessors:**
/// - `hash`, `size`, `mtime`, `mode` default to remoteFile (or localFile as fallback)
///
/// Example usage:
/// ```swift
/// // Addition: File exists only on source
/// let addOp = FileOperation(
///     action: .add,
///     path: "photos/new.jpg",
///     localFile: nil,
///     remoteFile: FileItem(...)
/// )
///
/// // Deletion: File exists only on dest
/// let deleteOp = FileOperation(
///     action: .delete,
///     path: "photos/old.jpg",
///     localFile: FileItem(...),
///     remoteFile: nil
/// )
///
/// // Conflict: Different content on both sides (sync mode only)
/// let conflictOp = FileOperation(
///     action: .conflict,
///     path: "document.txt",
///     localFile: FileItem(hash: oldHash, mtime: 1000, ...),
///     remoteFile: FileItem(hash: newHash, mtime: 2000, ...)
/// )
///
/// // Resolve conflict using newer file
/// if conflictOp.remoteFile!.mtime > conflictOp.localFile!.mtime {
///     // Use remote version
/// }
/// ```
public struct FileOperation: Equatable, Codable {
    /// The type of operation to perform
    public enum Action: Equatable, Codable {
        /// Add file from source to dest
        case add

        /// Modify dest file (update content/metadata)
        case modify

        /// Delete file from dest
        case delete

        /// Move file within dest (from oldPath to operation.path)
        case move(from: String)

        /// Conflict: File differs on both sides (sync mode only)
        ///
        /// Requires user-specified resolution strategy:
        /// - newer: Choose file with latest mtime
        /// - ask: Prompt user for decision
        /// - keepBoth: Rename and keep both versions
        case conflict
    }

    /// The operation to perform
    public let action: Action

    /// Target path (relative to dest root)
    ///
    /// For move operations, this is the destination path.
    /// The source path is in `Action.move(from:)`.
    public let path: String

    /// Destination/client file metadata (nil for additions)
    public let localFile: FileItem?

    /// Source/server file metadata (nil for deletions)
    public let remoteFile: FileItem?

    public init(
        action: Action,
        path: String,
        localFile: FileItem? = nil,
        remoteFile: FileItem? = nil
    ) {
        self.action = action
        self.path = path
        self.localFile = localFile
        self.remoteFile = remoteFile
    }
}

// MARK: - Convenience Accessors

extension FileOperation {
    /// Content hash (defaults to remoteFile, falls back to localFile)
    public var hash: Data {
        remoteFile?.hash ?? localFile?.hash ?? Data()
    }

    /// File size in bytes (defaults to remoteFile, falls back to localFile)
    public var size: Int64 {
        remoteFile?.size ?? localFile?.size ?? 0
    }

    /// Modification time (defaults to remoteFile, falls back to localFile)
    public var mtime: Int64 {
        remoteFile?.mtime ?? localFile?.mtime ?? 0
    }

    /// POSIX permissions (defaults to remoteFile, falls back to localFile)
    public var mode: UInt16? {
        remoteFile?.mode ?? localFile?.mode
    }
}

// MARK: - CustomStringConvertible

extension FileOperation: CustomStringConvertible {
    public var description: String {
        let actionStr: String
        switch action {
        case .add:
            actionStr = "add"
        case .modify:
            actionStr = "modify"
        case .delete:
            actionStr = "delete"
        case .move(let from):
            actionStr = "move(from: \(from))"
        case .conflict:
            actionStr = "conflict"
        }

        let hashHex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "FileOperation(action: .\(actionStr), path: \(path), hash: \(hashHex)..., size: \(size))"
    }
}
