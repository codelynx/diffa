import Foundation

/// File permissions representation
public struct FilePermissions: Equatable, Codable {
    /// POSIX permissions as octal value (e.g., 0o755)
    /// This is the canonical source of truth
    public let posix: UInt16

    /// Create from POSIX permissions value
    public init(posix: UInt16) {
        self.posix = posix
    }

    /// Symbolic representation (e.g., "rwxr-xr-x")
    /// Computed from posix - not stored to avoid data inconsistency
    public var symbolic: String {
        Self.toSymbolic(posix: posix)
    }

    /// Convert POSIX octal to symbolic representation
    /// - Parameter posix: POSIX permissions (e.g., 0o755)
    /// - Returns: Symbolic string (e.g., "rwxr-xr-x")
    private static func toSymbolic(posix: UInt16) -> String {
        let permissions = posix & 0o777
        var result = ""

        // Owner (user) permissions
        result += (permissions & 0o400) != 0 ? "r" : "-"
        result += (permissions & 0o200) != 0 ? "w" : "-"
        result += (permissions & 0o100) != 0 ? "x" : "-"

        // Group permissions
        result += (permissions & 0o040) != 0 ? "r" : "-"
        result += (permissions & 0o020) != 0 ? "w" : "-"
        result += (permissions & 0o010) != 0 ? "x" : "-"

        // Other permissions
        result += (permissions & 0o004) != 0 ? "r" : "-"
        result += (permissions & 0o002) != 0 ? "w" : "-"
        result += (permissions & 0o001) != 0 ? "x" : "-"

        return result
    }

    /// Octal string representation (e.g., "755")
    public var octalString: String {
        String(format: "%o", posix & 0o777)
    }
}

/// File metadata captured during snapshot
public struct Metadata: Codable {
    /// Last modification date
    public let modificationDate: Date

    /// File size in bytes
    public let size: Int64

    /// File permissions (chmod)
    public let permissions: FilePermissions

    /// File owner (username) - nil unless captureOwnership enabled
    public let owner: String?

    /// File group - nil unless captureOwnership enabled
    public let group: String?

    /// Create metadata
    public init(
        modificationDate: Date,
        size: Int64,
        permissions: FilePermissions,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.modificationDate = modificationDate
        self.size = size
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }
}

// MARK: - Equatable

extension Metadata: Equatable {
    public static func == (lhs: Metadata, rhs: Metadata) -> Bool {
        // Compare dates with 1 second tolerance (accounts for JSON encoding precision)
        let dateEqual = abs(lhs.modificationDate.timeIntervalSince1970 -
                           rhs.modificationDate.timeIntervalSince1970) < 1.0

        return dateEqual &&
               lhs.size == rhs.size &&
               lhs.permissions == rhs.permissions &&
               lhs.owner == rhs.owner &&
               lhs.group == rhs.group
    }
}
