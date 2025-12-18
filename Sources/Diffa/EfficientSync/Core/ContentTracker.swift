import Foundation

/// Tracks content presence in destination for zero-copy deduplication
///
/// **Purpose:**
/// During sync operations, ContentTracker enables zero-copy deduplication by
/// maintaining a mapping from content hash to file path. When content already
/// exists at destination, we copy from the existing file instead of transferring
/// from source (network transfer savings).
///
/// **Safety Features:**
/// 1. **Seeds from destination snapshot:** Only tracks existing content
/// 2. **Filters implicit deletions:** Mode-aware (push/pull delete dest-only/source-only files)
/// 3. **Filters move source paths:** Old paths become unavailable after moves
/// 4. **Normalizes paths:** Prevents directory traversal attacks (../, symlinks)
/// 5. **Deterministic seeding:** Sorted iteration ensures stable behavior
///
/// **Example Usage:**
/// ```swift
/// let tracker = ContentTracker(
///     sourceSnapshot: source,
///     destSnapshot: dest,
///     destRoot: URL(fileURLWithPath: "/data"),
///     operations: operations,
///     mode: .push
/// )
///
/// // Check if content exists before transfer
/// if let existingPath = tracker.canonicalPath(for: fileHash) {
///     // Copy locally: existingPath → targetPath (zero network transfer!)
///     try FileManager.default.copyItem(at: existingPath, to: targetPath)
/// } else {
///     // Transfer from source
///     try transferFromSource(hash: fileHash, to: targetPath)
/// }
///
/// // Record newly written content
/// tracker.recordWrittenContent(hash: fileHash, at: targetPath)
/// ```
///
/// **Thread Safety:** Not thread-safe. Use from single thread only.
public final class ContentTracker {
    /// Maps content hash → canonical file path (first occurrence, sorted)
    private var hashToCanonicalPath: [Data: URL] = [:]

    /// Destination root (normalized, symlinks resolved)
    private let destRoot: URL

    /// Initialize tracker with safe, deterministic seeding
    ///
    /// - Parameters:
    ///   - sourceSnapshot: Source snapshot (for mode-aware filtering)
    ///   - destSnapshot: Destination snapshot (existing content to track)
    ///   - destRoot: Destination root directory (symlinks will be resolved)
    ///   - operations: Planned operations (to filter deletions/moves)
    ///   - mode: Sync mode (affects implicit deletion filtering)
    public init(
        sourceSnapshot: SyncSnapshot,
        destSnapshot: SyncSnapshot,
        destRoot: URL,
        operations: [FileOperation],
        mode: SyncMode
    ) {
        // Normalize destRoot: resolve symlinks, standardize path
        self.destRoot = destRoot.resolvingSymlinksInPath().standardized

        // Collect paths that will be removed (mode-aware)
        let removedPaths = collectRemovedPaths(
            operations: operations,
            sourceSnapshot: sourceSnapshot,
            destSnapshot: destSnapshot,
            mode: mode
        )

        // Seed from destination snapshot (deterministically)
        // Files are sorted by path for stable hash→path mapping
        for file in destSnapshot.allFiles() {
            // Skip files that will be removed
            guard !removedPaths.contains(file.path) else {
                continue
            }

            // Map hash → first canonical path (sorted order)
            if hashToCanonicalPath[file.hash] == nil {
                let absolutePath = self.destRoot.appendingPathComponent(file.path)
                let normalizedPath = normalizeAndValidate(path: absolutePath)

                // Only track if path is safe
                if let safePath = normalizedPath {
                    hashToCanonicalPath[file.hash] = safePath
                }
            }
        }
    }

    /// Record newly written content (takes precedence over seeded paths)
    ///
    /// Call this after successfully writing a file to update the tracker.
    /// Newly written paths take precedence for future deduplication.
    ///
    /// - Parameters:
    ///   - hash: Content hash (MD5)
    ///   - url: Absolute path where content was written
    public func recordWrittenContent(hash: Data, at url: URL) {
        let normalizedPath = normalizeAndValidate(path: url)

        if let safePath = normalizedPath {
            hashToCanonicalPath[hash] = safePath
        }
    }

    /// Get canonical path for hash (for deduplication)
    ///
    /// Returns the first path (in sorted order) where this content exists.
    /// Returns nil if content not tracked.
    ///
    /// - Parameter hash: Content hash to look up
    /// - Returns: Absolute URL to existing file, or nil
    public func canonicalPath(for hash: Data) -> URL? {
        return hashToCanonicalPath[hash]
    }

    // MARK: - Internal Helpers

    /// Collect paths that will be removed during sync
    ///
    /// **Mode-aware filtering:**
    /// - **Push mode:** Implicit deletions (dest-only files) + explicit deletes
    /// - **Pull mode:** Implicit deletions (source-only files) + explicit deletes
    /// - **Sync mode:** Only explicit deletes (no implicit deletions)
    /// - **All modes:** Move source paths (old paths become unavailable)
    ///
    /// - Returns: Set of relative paths that will be removed
    private func collectRemovedPaths(
        operations: [FileOperation],
        sourceSnapshot: SyncSnapshot,
        destSnapshot: SyncSnapshot,
        mode: SyncMode
    ) -> Set<String> {
        var removed = Set<String>()

        // 1. Explicit deletions (all modes)
        for operation in operations {
            if case .delete = operation.action {
                removed.insert(operation.path)
            }
        }

        // 2. Move source paths (all modes)
        for operation in operations {
            if case .move(let from) = operation.action {
                removed.insert(from)
            }
        }

        // 3. Implicit deletions (mode-aware)
        switch mode {
        case .push:
            // Push mode: dest-only files are implicitly deleted
            let sourceFiles = Set(sourceSnapshot.allFiles().map { $0.path })
            let destFiles = Set(destSnapshot.allFiles().map { $0.path })

            for path in destFiles {
                if !sourceFiles.contains(path) {
                    removed.insert(path)
                }
            }

        case .pull:
            // Pull mode: source-only files are implicitly deleted (from dest perspective)
            // Actually, in pull mode, the source becomes the destination
            // So we need to check which files in dest will be deleted
            let sourceFiles = Set(sourceSnapshot.allFiles().map { $0.path })
            let destFiles = Set(destSnapshot.allFiles().map { $0.path })

            for path in destFiles {
                if !sourceFiles.contains(path) {
                    removed.insert(path)
                }
            }

        case .sync:
            // Sync mode: no implicit deletions (merge both sides)
            break
        }

        return removed
    }

    /// Normalize and validate path for security
    ///
    /// **Security checks:**
    /// 1. Resolve symlinks (prevent symlink attacks)
    /// 2. Standardize path (remove .., //, etc.)
    /// 3. Verify path is under destRoot (prevent directory traversal)
    ///
    /// - Parameter path: Path to normalize
    /// - Returns: Normalized URL if safe, nil otherwise
    private func normalizeAndValidate(path: URL) -> URL? {
        // Resolve symlinks and standardize
        let normalized = path.resolvingSymlinksInPath().standardized

        // Verify path is under destRoot
        let normalizedPath = normalized.path
        let rootPath = destRoot.path

        // Path must start with destRoot and not escape via ..
        guard normalizedPath.hasPrefix(rootPath) else {
            return nil
        }

        // Additional check: ensure no .. components after normalization
        if normalizedPath.contains("..") {
            return nil
        }

        return normalized
    }
}

// MARK: - CustomStringConvertible

extension ContentTracker: CustomStringConvertible {
    public var description: String {
        "ContentTracker(tracked: \(hashToCanonicalPath.count) hashes, root: \(destRoot.path))"
    }
}
