import Foundation
import Compression

/// Compression utilities for network sync
///
/// Uses Apple's Compression framework with ZLIB algorithm (gzip compatible)
public enum SyncCompression {

    /// Minimum file size to compress (4KB)
    public static let sizeThreshold: Int = 4096

    /// Extensions that are already compressed (skip compression)
    public static let incompressibleExtensions: Set<String> = [
        // Images
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif",
        // Video
        "mp4", "mov", "avi", "mkv", "webm", "m4v",
        // Audio
        "mp3", "aac", "m4a", "ogg", "flac", "opus",
        // Archives
        "zip", "gz", "gzip", "bz2", "xz", "7z", "rar", "tar.gz", "tgz",
        // Other compressed
        "pdf", "docx", "xlsx", "pptx", "jar", "dmg", "iso"
    ]

    /// Check if a file should be compressed
    public static func shouldCompress(path: String, size: Int) -> Bool {
        // Skip small files
        guard size >= sizeThreshold else { return false }

        // Skip already-compressed extensions
        let ext = (path as NSString).pathExtension.lowercased()
        if incompressibleExtensions.contains(ext) {
            return false
        }

        // Check compound extensions like .tar.gz
        let filename = (path as NSString).lastPathComponent.lowercased()
        for compExt in incompressibleExtensions {
            if filename.hasSuffix(".\(compExt)") {
                return false
            }
        }

        return true
    }

    /// Compress data using ZLIB (gzip compatible)
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return data }

        let destinationBufferSize = data.count  // Worst case: same size
        var destinationBuffer = Data(count: destinationBufferSize)

        let compressedSize = destinationBuffer.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                compression_encode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!,
                    destinationBufferSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard compressedSize > 0 else { return nil }

        // Only use compressed if it's actually smaller
        if compressedSize >= data.count {
            return nil  // Compression didn't help
        }

        destinationBuffer.count = compressedSize
        return destinationBuffer
    }

    /// Decompress ZLIB compressed data
    public static func decompress(_ data: Data, originalSize: Int) -> Data? {
        guard !data.isEmpty else { return data }

        var destinationBuffer = Data(count: originalSize)

        let decompressedSize = destinationBuffer.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!,
                    originalSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decompressedSize == originalSize else { return nil }

        return destinationBuffer
    }
}
