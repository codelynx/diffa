import Foundation

/// Internal class for reverting patch operations
class PatchReverter {
    private let fileManager = FileManager.default

    /// Revert an add operation - delete the added file/folder
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - targetDirectory: Base directory to revert in
    func revertAdd(path: String, from targetDirectory: URL) throws {
        let fullURL = targetDirectory.appendingPathComponent(path)

        // Check if item exists before trying to remove
        guard fileManager.fileExists(atPath: fullURL.path) else {
            // Item doesn't exist - already reverted (idempotent)
            return
        }

        try fileManager.removeItem(at: fullURL)
    }

    /// Revert a remove operation - restore the original file/folder
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - content: Original file content (nil for folders or symlinks)
    ///   - metadata: Original file metadata
    ///   - cacheReference: Symlink target path (for symlinks) or nil
    ///   - targetDirectory: Base directory to restore to
    func revertRemove(path: String, content: Data?, metadata: Metadata, cacheReference: String?, to targetDirectory: URL) throws {
        let fullURL = targetDirectory.appendingPathComponent(path)

        // Create parent directories if needed
        let parentURL = fullURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        // Check if this is a symlink (has cache_reference and no content)
        if let symlinkTarget = cacheReference, content == nil {
            // Restore symlink
            try fileManager.createSymbolicLink(atPath: fullURL.path, withDestinationPath: symlinkTarget)
        } else if let content = content {
            // Restore regular file with content
            try content.write(to: fullURL)
        } else {
            // Directory (no content, no symlink target)
            try fileManager.createDirectory(at: fullURL, withIntermediateDirectories: false)
        }

        // Restore metadata (permissions and modification date)
        try applyMetadata(metadata, to: fullURL)
    }

    /// Revert a modify operation - restore the original file content/metadata
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - originalContent: Original file content (nil for folders)
    ///   - metadata: Original file metadata
    ///   - targetDirectory: Base directory to restore to
    func revertModify(path: String, originalContent: Data?, metadata: Metadata, to targetDirectory: URL) throws {
        let fullURL = targetDirectory.appendingPathComponent(path)

        // If there's content, restore it (regular file)
        if let content = originalContent {
            try content.write(to: fullURL)
        }
        // If no content, it's a folder or large file - just restore metadata

        // Restore metadata (permissions and modification date)
        try applyMetadata(metadata, to: fullURL)
    }

    /// Revert a move operation - move file/folder back to original location
    /// - Parameters:
    ///   - fromPath: Current path (where it was moved to)
    ///   - toPath: Original path (where to move it back)
    ///   - targetDirectory: Base directory to move in
    func revertMove(from fromPath: String, to toPath: String, in targetDirectory: URL) throws {
        let currentURL = targetDirectory.appendingPathComponent(fromPath)
        let originalURL = targetDirectory.appendingPathComponent(toPath)

        // Create parent directory for original location if needed
        let parentURL = originalURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        try fileManager.moveItem(at: currentURL, to: originalURL)
    }

    /// Apply metadata (permissions and modification date) to a file or folder
    /// - Parameters:
    ///   - metadata: Metadata to apply
    ///   - url: URL of file or folder
    private func applyMetadata(_ metadata: Metadata, to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]

        // Set permissions
        attributes[.posixPermissions] = metadata.permissions.posix

        // Set modification date
        attributes[.modificationDate] = metadata.modificationDate

        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
