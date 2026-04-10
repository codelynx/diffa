import Foundation
import CZlib

/// Compression utilities for network sync
///
/// Uses zlib raw deflate for cross-platform compatibility (macOS and Linux)
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

    /// Compress data using zlib raw deflate
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return data }

        let destinationBufferSize = Int(compressBound(uLong(data.count)))
        var destinationBuffer = Data(count: destinationBufferSize)

        var stream = z_stream()
        let initResult = data.withUnsafeBytes { srcPtr -> Int32 in
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcPtr.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            // windowBits = -15: raw deflate (no header), matching Apple's COMPRESSION_ZLIB
            return deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                 -15, 8, Z_DEFAULT_STRATEGY,
                                 ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }

        guard initResult == Z_OK else { return nil }

        let compressedSize = destinationBuffer.withUnsafeMutableBytes { destPtr -> Int in
            stream.next_out = destPtr.bindMemory(to: UInt8.self).baseAddress!
            stream.avail_out = uInt(destinationBufferSize)

            let result = deflate(&stream, Z_FINISH)
            deflateEnd(&stream)

            guard result == Z_STREAM_END else { return 0 }
            return Int(stream.total_out)
        }

        guard compressedSize > 0 else { return nil }

        // Only use compressed if it's actually smaller
        if compressedSize >= data.count {
            return nil  // Compression didn't help
        }

        destinationBuffer.count = compressedSize
        return destinationBuffer
    }

    /// Decompress zlib raw deflate data
    public static func decompress(_ data: Data, originalSize: Int) -> Data? {
        guard !data.isEmpty else { return data }

        var destinationBuffer = Data(count: originalSize)

        var stream = z_stream()
        let initResult = data.withUnsafeBytes { srcPtr -> Int32 in
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcPtr.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            // windowBits = -15: raw deflate (no header)
            return inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }

        guard initResult == Z_OK else { return nil }

        let decompressedSize = destinationBuffer.withUnsafeMutableBytes { destPtr -> Int in
            stream.next_out = destPtr.bindMemory(to: UInt8.self).baseAddress!
            stream.avail_out = uInt(originalSize)

            let result = inflate(&stream, Z_FINISH)
            inflateEnd(&stream)

            guard result == Z_STREAM_END else { return 0 }
            return Int(stream.total_out)
        }

        guard decompressedSize == originalSize else { return nil }

        return destinationBuffer
    }
}
