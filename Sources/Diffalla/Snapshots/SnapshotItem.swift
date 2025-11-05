import Foundation

/// Represents an item loaded from a snapshot database
public struct SnapshotItem: Codable, Equatable {
    /// Database row ID
    public let id: Int64

    /// Parent item ID (nil for root-level items)
    public let parentId: Int64?

    /// Relative path from snapshot root
    public let path: String

    /// File or directory name (last path component)
    public let name: String

    /// True if this is a directory
    public let isFolder: Bool

    /// Size in bytes (0 for directories)
    public let size: Int64

    /// Last modification date
    public let modificationDate: Date

    /// File permissions
    public let permissions: FilePermissions

    /// Owner username (optional)
    public let owner: String?

    /// Group name (optional)
    public let group: String?

    /// SHA-256 hash (nil for directories and when not computed)
    public let sha256: String?

    public init(
        id: Int64,
        parentId: Int64?,
        path: String,
        name: String,
        isFolder: Bool,
        size: Int64,
        modificationDate: Date,
        permissions: FilePermissions,
        owner: String?,
        group: String?,
        sha256: String?
    ) {
        self.id = id
        self.parentId = parentId
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.sha256 = sha256
    }
}
