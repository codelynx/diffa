import Foundation
import CommonCrypto

/// A file or folder read from the file system
///
/// **Behavior:**
/// - Symlink handling controlled by `followSymlinks` parameter:
///   - `followSymlinks: true` - reads target's attributes and computes SHA-256 of target content
///   - `followSymlinks: false` - reads symlink's own attributes, no SHA-256 hash
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
    ///   - pathOverride: Optional URL to use for path computation (for symlinks)
    ///   - followSymlinks: Whether to follow symlinks (true) or read symlink itself (false)
    ///   - hashCache: Optional hash cache for faster hash lookups
    ///   - cacheStatsCallback: Optional callback to report cache hits/misses (hit: Bool) -> Void
    ///   - parallelHasher: Optional helper that runs hash computations on a parallel queue
    public init(
        at url: URL,
        relativeTo baseURL: URL,
        captureOwnership: Bool = false,
        pathOverride: URL? = nil,
        followSymlinks: Bool = true,
        hashCache: HashCache? = nil,
        cacheStatsCallback: ((Bool) -> Void)? = nil,
        parallelHasher: ParallelHasher? = nil
    ) throws {
        let fileManager = FileManager.default

        // Check if this is a symlink
        let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let isSymlink = resourceValues.isSymbolicLink ?? false

        // Get file attributes
        // For symlinks when followSymlinks=false, we need special handling
        let attributes: [FileAttributeKey: Any]
        if isSymlink && !followSymlinks {
            // Use lstat-equivalent to read symlink itself, not target
            // FileManager doesn't have a direct lstat equivalent, so we use URL resource values
            attributes = try Self.getSymlinkAttributes(at: url, fileManager: fileManager)
        } else {
            // Normal case: follows symlinks
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        }

        // Determine if folder
        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory

        // Normalize URLs to handle symlinks like /var -> /private/var on macOS
        let normalizedURL = (pathOverride ?? url).standardizedFileURL
        let normalizedBaseURL = baseURL.standardizedFileURL

        // Compute relative path by removing base prefix
        let basePath = normalizedBaseURL.path
        let fullPath = normalizedURL.path

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

            // Safety check: ensure prefix length doesn't exceed full path length
            guard prefixLength <= fullPath.count else {
                throw FileSystemError.fileNotUnderBasePath(
                    filePath: fullPath,
                    basePath: basePath
                )
            }

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
        // Skip hash computation for symlinks when not following them
        var hash: String?
        if !isDirectory && !(isSymlink && !followSymlinks) {
            // Try cache lookup first if cache is available
            if let cache = hashCache {
                // Try to get cached hash
                if let cachedHash = try cache.lookup(path: relativePath, size: fileSize, modificationDate: modDate) {
                    // Cache hit!
                    hash = cachedHash
                    cacheStatsCallback?(true) // Report cache hit
                } else {
                    // Cache miss - compute hash and store
                    if let hasher = parallelHasher {
                        hash = try hasher.hashFile(at: url)
                    } else {
                        hash = try Self.computeHash(at: url)
                    }
                    try cache.store(path: relativePath, size: fileSize, modificationDate: modDate, hash: hash!)
                    cacheStatsCallback?(false) // Report cache miss
                }
            } else {
                // No cache - compute hash normally
                if let hasher = parallelHasher {
                    hash = try hasher.hashFile(at: url)
                } else {
                    hash = try Self.computeHash(at: url)
                }
            }
        }

        // Initialize
        self.path = relativePath
        self.isFolder = isDirectory
        self.sha256 = hash
        self.size = fileSize
        self.metadata = metadata
    }

    /// Get attributes of a symlink itself (not its target)
    /// - Parameters:
    ///   - url: Symlink URL
    ///   - fileManager: FileManager instance
    /// - Returns: Dictionary of file attributes for the symlink itself
    private static func getSymlinkAttributes(at url: URL, fileManager: FileManager) throws -> [FileAttributeKey: Any] {
        // Get resource values that don't follow symlinks
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey
        ]

        let values = try url.resourceValues(forKeys: resourceKeys)

        // Convert to FileAttributeKey format
        var attributes: [FileAttributeKey: Any] = [:]

        // Symlinks are always "files" (not directories) in our model
        attributes[.type] = FileAttributeType.typeSymbolicLink

        // Size of symlink itself (typically small, just the path string)
        if let size = values.fileSize {
            attributes[.size] = Int64(size)
        } else {
            attributes[.size] = Int64(0)
        }

        // Modification date
        if let modDate = values.contentModificationDate {
            attributes[.modificationDate] = modDate
        } else {
            throw FileSystemError.missingMetadata(path: url.path, field: "modificationDate")
        }

        // Get POSIX permissions using lstat via FileManager
        // We need to use a lower-level API for this
        var stat = Darwin.stat()
        if lstat(url.path, &stat) == 0 {
            attributes[.posixPermissions] = UInt16(stat.st_mode & 0o7777)
        } else {
            attributes[.posixPermissions] = UInt16(0o644) // Default
        }

        return attributes
    }

    /// Read file metadata without computing hash or path
    /// - Parameters:
    ///   - url: Absolute URL to the file or folder
    ///   - captureOwnership: Whether to capture file owner/group (default: false)
    ///   - followSymlinks: Whether to follow symlinks (true) or read symlink itself (false)
    /// - Returns: File metadata
    static func readMetadata(at url: URL, captureOwnership: Bool = false, followSymlinks: Bool = true) throws -> Metadata {
        let fileManager = FileManager.default

        // Check if this is a symlink
        let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let isSymlink = resourceValues.isSymbolicLink ?? false

        // Get file attributes (symlink-aware if needed)
        let attributes: [FileAttributeKey: Any]
        if isSymlink && !followSymlinks {
            // Read symlink itself, not target
            attributes = try Self.getSymlinkAttributes(at: url, fileManager: fileManager)
        } else {
            // Normal case: follows symlinks
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        }

        // Get file type
        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory

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

        return Metadata(
            modificationDate: modDate,
            size: fileSize,
            permissions: permissions,
            owner: owner,
            group: group
        )
    }

    /// Read symlink target path
    /// - Parameter url: URL of the symlink
    /// - Returns: Target path that the symlink points to
    static func readSymlinkTarget(at url: URL) throws -> String {
        let fileManager = FileManager.default
        return try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Compute SHA-256 hash of file content
    /// - Parameter url: File URL to hash
    /// - Returns: Hex-encoded SHA-256 hash
    static func computeHash(at url: URL) throws -> String {
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
