import Foundation
import CommonCrypto

/// A file or folder read from the file system
///
/// **Behavior:**
/// - Always follows symlinks (uses FileManager.attributesOfItem)
/// - Does not filter hidden files (reads any file it's given)
/// - Does not recursively scan directories
///
/// **Note:** Filtering and recursive scanning are handled by the scanner (Step 4).
/// FileSystemItem is a low-level reader for a single file/folder.
public struct FileSystemItem: ItemProtocol {
    /// Relative path from snapshot root
    public let path: String

    /// True if this is a directory, false for files
    public let isFolder: Bool

    /// SHA-256 hash of file content (nil for folders)
    public let sha256: String?

    /// Size in bytes (file size or 0 for folders)
    public let size: Int64

    /// File system metadata
    public let metadata: Metadata

    /// Create FileSystemItem by reading from disk
    /// - Parameters:
    ///   - url: Absolute URL to the file or folder
    ///   - baseURL: Base URL for computing relative path
    ///   - captureOwnership: Whether to capture file owner/group
    public init(at url: URL, relativeTo baseURL: URL, captureOwnership: Bool = false) throws {
        let fileManager = FileManager.default

        // Get file attributes
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        // Determine if folder
        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory

        // Compute relative path by removing base prefix
        let basePath = baseURL.path
        let fullPath = url.path

        // Ensure the file is actually under the base path (with proper path component boundaries)
        let isUnderBase: Bool
        if basePath == "/" {
            // Root: everything is under root
            isUnderBase = fullPath.hasPrefix("/")
        } else if fullPath == basePath {
            // Exact match
            isUnderBase = true
        } else if fullPath.hasPrefix(basePath + "/") {
            // File is under base directory (next character must be "/")
            isUnderBase = true
        } else if basePath.hasSuffix("/") && fullPath.hasPrefix(basePath) {
            // Base has trailing slash and file starts with it
            isUnderBase = true
        } else {
            isUnderBase = false
        }

        guard isUnderBase else {
            throw FileSystemError.fileNotUnderBasePath(
                filePath: fullPath,
                basePath: basePath
            )
        }

        // Remove base path prefix, handling trailing slash
        let relativePath: String
        if basePath == "/" {
            // Root snapshot: remove leading "/" only
            relativePath = String(fullPath.dropFirst())
        } else if fullPath == basePath {
            // File is exactly the base path (shouldn't happen for snapshots, but handle it)
            relativePath = ""
        } else {
            // Normal case: remove base path + separator
            let prefixLength = basePath.hasSuffix("/") ? basePath.count : basePath.count + 1
            relativePath = String(fullPath.dropFirst(prefixLength))
        }

        // Get size (0 for directories)
        let fileSize = isDirectory ? 0 : (attributes[.size] as? Int64 ?? 0)

        // Get modification date
        guard let modDate = attributes[.modificationDate] as? Date else {
            throw FileSystemError.missingMetadata(path: url.path, field: "modificationDate")
        }

        // Get permissions
        let posixPerms = attributes[.posixPermissions] as? UInt16 ?? 0o644
        let permissions = FilePermissions(posix: posixPerms)

        // Get ownership if requested
        var owner: String?
        var group: String?
        if captureOwnership {
            owner = attributes[.ownerAccountName] as? String
            group = attributes[.groupOwnerAccountName] as? String
        }

        // Create metadata
        let metadata = Metadata(
            modificationDate: modDate,
            size: fileSize,
            permissions: permissions,
            owner: owner,
            group: group
        )

        // Compute hash for files only
        var hash: String?
        if !isDirectory {
            hash = try Self.computeHash(at: url)
        }

        // Initialize
        self.path = relativePath
        self.isFolder = isDirectory
        self.sha256 = hash
        self.size = fileSize
        self.metadata = metadata
    }

    /// Compute SHA-256 hash of file content
    /// - Parameter url: File URL to hash
    /// - Returns: Hex-encoded SHA-256 hash
    private static func computeHash(at url: URL) throws -> String {
        // Open file for reading
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw FileSystemError.cannotOpenFile(path: url.path)
        }
        defer { try? fileHandle.close() }

        // Initialize SHA-256 context
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        // Read file in chunks
        let bufferSize = 64 * 1024 // 64 KB chunks
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty {
                return false // EOF
            }
            data.withUnsafeBytes { bufferPointer in
                _ = CC_SHA256_Update(&context, bufferPointer.baseAddress, CC_LONG(data.count))
            }
            return true // Continue
        }) {}

        // Finalize hash
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)

        // Convert to hex string
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Equatable

extension FileSystemItem: Equatable {
    public static func == (lhs: FileSystemItem, rhs: FileSystemItem) -> Bool {
        lhs.path == rhs.path &&
        lhs.isFolder == rhs.isFolder &&
        lhs.sha256 == rhs.sha256 &&
        lhs.size == rhs.size &&
        lhs.metadata == rhs.metadata
    }
}

// MARK: - Errors

enum FileSystemError: Error, CustomStringConvertible {
    case missingMetadata(path: String, field: String)
    case cannotOpenFile(path: String)
    case hashComputationFailed(path: String, underlying: Error)
    case fileNotUnderBasePath(filePath: String, basePath: String)

    var description: String {
        switch self {
        case .missingMetadata(let path, let field):
            return "Missing metadata field '\(field)' for: \(path)"
        case .cannotOpenFile(let path):
            return "Cannot open file for reading: \(path)"
        case .hashComputationFailed(let path, let error):
            return "Hash computation failed for \(path): \(error)"
        case .fileNotUnderBasePath(let filePath, let basePath):
            return "File '\(filePath)' is not under base path '\(basePath)'"
        }
    }
}
