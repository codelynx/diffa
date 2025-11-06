import Foundation

/// Internal class for applying patch operations to directories
class PatchApplicator {
    private let fileManager = FileManager.default

    /// Apply an add operation - create file or folder with content and metadata
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - isFolder: True if creating a directory
    ///   - content: File content (nil for folders)
    ///   - metadata: File metadata (permissions, dates)
    ///   - targetDirectory: Base directory to apply to
    func applyAdd(path: String, isFolder: Bool, content: Data?, metadata: Metadata, to targetDirectory: URL) throws {
        let fullURL = targetDirectory.appendingPathComponent(path)

        // Create parent directories if needed
        let parentURL = fullURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        if isFolder {
            // Create directory
            try fileManager.createDirectory(at: fullURL, withIntermediateDirectories: false)
        } else {
            // Create file with content
            guard let content = content else {
                throw DiffaError.invalidPatch(
                    reason: "Cannot apply add operation for '\(path)': content is missing. This indicates a corrupt or incomplete patch."
                )
            }
            try content.write(to: fullURL)
        }

        // Set metadata (permissions and modification date)
        try applyMetadata(metadata, to: fullURL)
    }

    /// Apply a remove operation - delete file or folder
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - targetDirectory: Base directory to apply to
    func applyRemove(path: String, from targetDirectory: URL) throws {
        let fullURL = targetDirectory.appendingPathComponent(path)

        // Check if item exists before trying to remove
        guard fileManager.fileExists(atPath: fullURL.path) else {
            // Item doesn't exist - skip (idempotent)
            return
        }

        try fileManager.removeItem(at: fullURL)
    }

    /// Apply a modify operation - update file content and metadata
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - isFolder: True if modifying a directory
    ///   - content: New file content (nil for folders)
    ///   - metadata: Updated file metadata
    ///   - targetDirectory: Base directory to apply to
    func applyModify(path: String, isFolder: Bool, content: Data?, metadata: Metadata, to targetDirectory: URL) throws {
        let fullURL = targetDirectory.appendingPathComponent(path)

        if !isFolder {
            // Update file content - required for file modifications
            guard let content = content else {
                throw DiffaError.invalidPatch(
                    reason: "Cannot apply modify operation for '\(path)': content is missing. This indicates a corrupt or incomplete patch."
                )
            }
            try content.write(to: fullURL)
        }

        // Update metadata (permissions and modification date)
        try applyMetadata(metadata, to: fullURL)
    }

    /// Apply a move operation - rename or move file/folder
    /// - Parameters:
    ///   - fromPath: Original relative path
    ///   - toPath: New relative path
    ///   - targetDirectory: Base directory to apply to
    func applyMove(from fromPath: String, to toPath: String, in targetDirectory: URL) throws {
        let sourceURL = targetDirectory.appendingPathComponent(fromPath)
        let destURL = targetDirectory.appendingPathComponent(toPath)

        // Create parent directory for destination if needed
        let parentURL = destURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        try fileManager.moveItem(at: sourceURL, to: destURL)
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
