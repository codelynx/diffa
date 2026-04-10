import Foundation

/// File system scanner with streaming callback pattern
///
/// **Design:**
/// - Streaming: Processes files one at a time via callback (no accumulation)
/// - Memory efficient: Suitable for large directory trees (100k+ files)
/// - Excludes directories: Only processes regular files
/// - Relative paths: All paths are relative to scan root
///
/// **Example:**
/// ```swift
/// let scanner = FileSystemScanner()
/// let root = URL(fileURLWithPath: "/data/photos")
///
/// try scanner.scan(root: root) { url, metadata in
///     print("Found: \(metadata.path) (\(metadata.size) bytes)")
///     // Process immediately - no accumulation
/// }
/// ```
public struct FileSystemScanner {
    public init() {}

    /// Scan directory and invoke callback for each file (streaming, memory efficient)
    ///
    /// Traverses directory tree recursively, invoking callback for each regular file.
    /// Directories are skipped. Files are processed in filesystem order (unspecified).
    ///
    /// **Performance:**
    /// - Memory: O(depth) for recursion stack, not O(files)
    /// - Speed: Limited by filesystem I/O and callback execution
    ///
    /// - Parameters:
    ///   - root: Directory to scan (absolute path)
    ///   - onFile: Callback invoked for each file (url is absolute, metadata.path is relative)
    /// - Throws: FileSystemError if scan fails
    public func scan(
        root: URL,
        onFile: (URL, FileMetadata) throws -> Void
    ) throws {
        // Verify root exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScannerError.notADirectory(path: root.path)
        }

        // Create enumerator with resource keys we need
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [], // No options - include all files
            errorHandler: { url, error in
                // Log error but continue scanning
                // Return true to continue enumeration
                return true
            }
        ) else {
            throw ScannerError.enumerationFailed(path: root.path)
        }

        // Process each item
        while let url = enumerator.nextObject() as? URL {
            // Check if it's a directory
            let resourceValues = try url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            if resourceValues.isDirectory == true {
                // Skip internal staging/temp directories at sync root only
                if url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".diffa_temp_") || name == ".diffa_staging" {
                        enumerator.skipDescendants()
                    }
                }
                continue // Skip directories
            }

            // Skip internal temp files at sync root only
            if url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
                let fileName = url.lastPathComponent
                if fileName.hasPrefix(".diffa_temp_") {
                    continue
                }
            }

            // Get file metadata
            let attrs = try url.resourceValues(forKeys: [
                URLResourceKey.fileSizeKey,
                URLResourceKey.contentModificationDateKey
            ])

            // Get POSIX permissions through FileManager (if available)
            var mode: UInt16? = nil
            if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let permissions = fileAttrs[.posixPermissions] as? NSNumber {
                mode = UInt16(permissions.uint16Value)
            }

            // Compute relative path
            let relativePath = computeRelativePath(from: root, to: url)

            // Create metadata
            let metadata = FileMetadata(
                path: relativePath,
                size: Int64(attrs.fileSize ?? 0),
                mtime: Int64(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0),
                mode: mode
            )

            // Invoke callback immediately (streaming - no accumulation)
            try onFile(url, metadata)
        }
    }

    /// Compute relative path from root to url
    ///
    /// - Parameters:
    ///   - root: Base directory
    ///   - url: File URL (must be under root)
    /// - Returns: Relative path (e.g., "photos/vacation.jpg")
    private func computeRelativePath(from root: URL, to url: URL) -> String {
        // Use URL's path components for reliable relative path computation
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents

        // Find where they diverge
        guard urlComponents.count > rootComponents.count else {
            return url.lastPathComponent
        }

        // Check if url is actually under root
        for (index, component) in rootComponents.enumerated() {
            if index >= urlComponents.count || urlComponents[index] != component {
                // Not under root, return full path
                return url.path
            }
        }

        // Extract relative components
        let relativeComponents = Array(urlComponents[rootComponents.count...])
        return relativeComponents.joined(separator: "/")
    }
}

// MARK: - Errors

/// File system scanner errors
public enum ScannerError: Error, CustomStringConvertible {
    case notADirectory(path: String)
    case enumerationFailed(path: String)
    case accessDenied(path: String)

    public var description: String {
        switch self {
        case .notADirectory(let path):
            return "Not a directory: \(path)"
        case .enumerationFailed(let path):
            return "Directory enumeration failed: \(path)"
        case .accessDenied(let path):
            return "Access denied: \(path)"
        }
    }
}
