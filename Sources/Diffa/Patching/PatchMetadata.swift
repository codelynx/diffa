import Foundation

/// Metadata about a patch
public struct PatchMetadata: Codable, Equatable {
    /// Patch format version
    public let version: Int

    /// When the patch was created
    public let createdDate: Date

    /// Optional checksum of source state for verification
    public let sourceChecksum: String?

    /// Optional checksum of target state for verification
    public let targetChecksum: String?

    /// Number of operations in the patch
    public let operationCount: Int

    /// Create patch metadata
    /// - Parameters:
    ///   - version: Patch format version
    ///   - createdDate: Creation timestamp
    ///   - sourceChecksum: Optional source verification checksum
    ///   - targetChecksum: Optional target verification checksum
    ///   - operationCount: Number of operations
    public init(
        version: Int,
        createdDate: Date,
        sourceChecksum: String? = nil,
        targetChecksum: String? = nil,
        operationCount: Int
    ) {
        self.version = version
        self.createdDate = createdDate
        self.sourceChecksum = sourceChecksum
        self.targetChecksum = targetChecksum
        self.operationCount = operationCount
    }
}
