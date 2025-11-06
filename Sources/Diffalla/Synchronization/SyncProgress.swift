import Foundation

/// Progress information during synchronization
public struct SyncProgress {
    /// Description of the current operation being performed
    public let currentOperation: String

    /// Number of files processed so far
    public let filesProcessed: Int

    /// Total number of files to process (nil if unknown)
    public let totalFiles: Int?

    /// Bytes transferred so far
    public let bytesTransferred: Int64

    /// Total bytes to transfer (nil if unknown)
    public let totalBytes: Int64?

    /// Type of operation currently being performed
    public let operationType: OperationType

    public init(
        currentOperation: String,
        filesProcessed: Int,
        totalFiles: Int?,
        bytesTransferred: Int64,
        totalBytes: Int64?,
        operationType: OperationType
    ) {
        self.currentOperation = currentOperation
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.operationType = operationType
    }
}

/// Type of synchronization operation
public enum OperationType: String, Codable {
    case comparing
    case copying
    case deleting
    case moving
}
