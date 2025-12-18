import Foundation
import CryptoKit

/// SHA-256 file hasher with streaming for memory efficiency
///
/// **Design:**
/// - Streams file content in 64KB chunks (no full file in memory)
/// - Returns 32-byte SHA-256 hash as Data
/// - Suitable for large files (GB+)
/// - Consistent with Phase 1-5 hash algorithm
///
/// **Example:**
/// ```swift
/// let hasher = FileHasher()
/// let hash = try hasher.hash(fileAt: fileURL)  // 32 bytes
/// ```
public struct FileHasher {
    /// Buffer size for streaming (64 KB)
    private let bufferSize = 64 * 1024

    public init() {}

    /// Hash file content using SHA-256 (streaming for large files)
    ///
    /// - Parameter url: File URL to hash
    /// - Returns: SHA-256 hash as 32-byte Data
    /// - Throws: HasherError if file cannot be read
    public func hash(fileAt url: URL) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw HasherError.cannotOpenFile(path: url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()

        // Stream in chunks (memory efficient for large files)
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) { }

        return Data(hasher.finalize())
    }

    /// Hash file and return hex string (convenience)
    ///
    /// - Parameter url: File URL to hash
    /// - Returns: SHA-256 hash as 64-character hex string
    public func hashHex(fileAt url: URL) throws -> String {
        let hash = try hash(fileAt: url)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

/// File hasher errors
public enum HasherError: Error, CustomStringConvertible {
    case cannotOpenFile(path: String)

    public var description: String {
        switch self {
        case .cannotOpenFile(let path):
            return "Cannot open file for hashing: \(path)"
        }
    }
}
