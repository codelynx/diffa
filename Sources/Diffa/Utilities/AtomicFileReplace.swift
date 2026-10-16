import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// Error thrown when an atomic file replacement fails.
public struct FileReplaceError: Error, LocalizedError, CustomStringConvertible {
    /// The staged file that was supposed to move into place
    public let source: URL

    /// The file that was supposed to be replaced (left untouched on failure)
    public let destination: URL

    /// `errno` on POSIX platforms, `GetLastError()` on Windows
    public let code: Int32

    public var description: String {
        "Failed to replace \(destination.path) with \(source.path) (error \(code))"
    }

    public var errorDescription: String? { description }
}

/// Write-then-swap helpers for replacing a file without ever leaving the
/// destination deleted or half-written.
///
/// Typical use:
/// ```swift
/// let staging = try AtomicFileReplace.stagingURL(for: destination)
/// defer { AtomicFileReplace.discardStaging(staging) }
/// try writeEverything(to: staging)
/// try AtomicFileReplace.replaceItem(at: destination, withItemAt: staging)
/// ```
///
/// Either the old destination or the complete new file is on disk at every
/// point; a failure anywhere leaves the old destination untouched.
public enum AtomicFileReplace {
    /// Returns a fresh, not-yet-existing URL to write a file to before
    /// swapping it over `destination`. The URL is on the same volume as
    /// `destination`, which is what makes the final swap atomic.
    ///
    /// - Darwin: inside a new `itemReplacementDirectory` for that volume.
    ///   This works under the App Sandbox even when only `destination`
    ///   itself was granted (e.g. via a save panel).
    /// - Linux / Windows: a hidden sibling file next to `destination`.
    ///
    /// Always pair with `discardStaging(_:)` (usually in a `defer`).
    public static func stagingURL(for destination: URL) throws -> URL {
        let name = ".\(destination.lastPathComponent).\(UUID().uuidString).staging"
        #if canImport(Darwin)
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(),
            create: true
        )
        return directory.appendingPathComponent(name)
        #else
        return destination.deletingLastPathComponent().appendingPathComponent(name)
        #endif
    }

    /// Atomically replaces `destination` with the file at `source`, or
    /// moves `source` into place if `destination` doesn't exist yet.
    ///
    /// `source` should come from `stagingURL(for:)` so both are on the same
    /// volume. On failure nothing has changed: `destination` is untouched
    /// and `source` is still in place for the caller to discard.
    ///
    /// - Darwin: `FileManager.replaceItemAt` (sandbox-safe swap).
    /// - Linux: `rename(2)`, which replaces the target in one step.
    /// - Windows: `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`.
    public static func replaceItem(at destination: URL, withItemAt source: URL) throws {
        #if canImport(Darwin)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        #elseif os(Windows)
        let sourcePath = source.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let destinationPath = destination.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let flags = DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH)
        let succeeded = sourcePath.withCString(encodedAs: UTF16.self) { wideSource in
            destinationPath.withCString(encodedAs: UTF16.self) { wideDestination in
                MoveFileExW(wideSource, wideDestination, flags)
            }
        }
        guard succeeded else {
            throw FileReplaceError(source: source, destination: destination, code: Int32(bitPattern: GetLastError()))
        }
        #else
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                rename(sourcePath!, destinationPath!)
            }
        }
        guard result == 0 else {
            throw FileReplaceError(source: source, destination: destination, code: errno)
        }
        #endif
    }

    /// Removes whatever is left at a staging URL (a no-op after a successful
    /// `replaceItem`) and, on Darwin, its temporary replacement directory.
    /// Never touches the destination.
    public static func discardStaging(_ stagingURL: URL) {
        try? FileManager.default.removeItem(at: stagingURL)
        #if canImport(Darwin)
        // rmdir only removes an empty directory, so a wrong URL can never
        // take a populated folder with it.
        _ = stagingURL.deletingLastPathComponent().withUnsafeFileSystemRepresentation { rmdir($0!) }
        #endif
    }
}
