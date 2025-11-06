import Foundation

/// An operation to perform during synchronization
enum SyncOperation {
    /// Copy a file from source to destination
    case copyFile(from: URL, to: URL, size: Int64)

    /// Delete a file at the given location
    case deleteFile(at: URL)

    /// Create a directory at the given location
    case createDirectory(at: URL)

    /// Delete a directory at the given location
    case deleteDirectory(at: URL)
}
