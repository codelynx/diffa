import Foundation

/// Network protocol messages for EfficientSync
///
/// **Protocol Overview:**
/// 1. Client connects to server
/// 2. Client sends HELLO with mode (push/pull)
/// 3. Server sends OK
/// 4. Client sends snapshot metadata (CSV)
/// 5. Server sends snapshot metadata (CSV)
/// 6. Both compute operations locally
/// 7. File transfer phase (requester asks for files)
/// 8. DONE message ends session
///
/// **Message Format:**
/// - Header: `<TYPE> <LENGTH>\n`
/// - Body: `<LENGTH bytes>`

public enum SyncMessageType: String {
    case hello = "HELLO"
    case ok = "OK"
    case error = "ERROR"
    case metadata = "METADATA"
    case requestFile = "REQUEST"
    case fileData = "FILE"
    case deleteFile = "DELETE"
    case done = "DONE"
}

/// Sync mode for network protocol
public enum NetworkSyncMode: String {
    case push = "PUSH"   // Client → Server
    case pull = "PULL"   // Server → Client
}

/// Message envelope for network protocol
public struct SyncMessage {
    public let type: SyncMessageType
    public let payload: Data

    public init(type: SyncMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public init(type: SyncMessageType, string: String) {
        self.type = type
        self.payload = string.data(using: .utf8) ?? Data()
    }

    /// Encode message for transmission
    public func encode() -> Data {
        var data = Data()
        let header = "\(type.rawValue) \(payload.count)\n"
        data.append(header.data(using: .utf8)!)
        data.append(payload)
        return data
    }

    /// Decode message from stream
    public static func decode(from stream: InputStream) throws -> SyncMessage {
        // Read header line
        var headerBytes: [UInt8] = []
        var byte: UInt8 = 0

        while stream.read(&byte, maxLength: 1) == 1 {
            if byte == 0x0A { // newline
                break
            }
            headerBytes.append(byte)
        }

        guard let headerString = String(bytes: headerBytes, encoding: .utf8) else {
            throw SyncProtocolError.invalidHeader
        }

        let parts = headerString.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let type = SyncMessageType(rawValue: String(parts[0])),
              let length = Int(parts[1]) else {
            throw SyncProtocolError.invalidHeader
        }

        // Read payload
        var payload = Data(count: length)
        if length > 0 {
            let bytesRead = payload.withUnsafeMutableBytes { buffer in
                stream.read(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: length)
            }
            guard bytesRead == length else {
                throw SyncProtocolError.incompletePayload
            }
        }

        return SyncMessage(type: type, payload: payload)
    }
}

// MARK: - Metadata Encoding

/// File metadata for network transfer (CSV format)
public struct NetworkFileItem: Codable {
    public let path: String
    public let size: Int64
    public let hash: String  // Hex-encoded
    public let mtime: Int64

    public init(path: String, size: Int64, hash: String, mtime: Int64) {
        self.path = path
        self.size = size
        self.hash = hash
        self.mtime = mtime
    }

    public init(from item: FileItem) {
        self.path = item.path
        self.size = item.size
        self.hash = item.hash.map { String(format: "%02x", $0) }.joined()
        self.mtime = item.mtime
    }

    public func toFileItem() -> FileItem {
        let hashData = Data(stride(from: 0, to: hash.count, by: 2).compactMap {
            UInt8(hash[hash.index(hash.startIndex, offsetBy: $0)..<hash.index(hash.startIndex, offsetBy: $0 + 2)], radix: 16)
        })
        return FileItem(path: path, size: size, hash: hashData, mtime: mtime, mode: nil)
    }

    /// Encode items to CSV
    public static func encodeCSV(_ items: [NetworkFileItem]) -> Data {
        var csv = "path,size,hash,mtime\n"
        for item in items {
            // Escape path (replace newlines and commas)
            let escapedPath = item.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
            csv += "\(escapedPath),\(item.size),\(item.hash),\(item.mtime)\n"
        }
        return csv.data(using: .utf8) ?? Data()
    }

    /// Decode items from CSV
    public static func decodeCSV(_ data: Data) -> [NetworkFileItem] {
        guard let csv = String(data: data, encoding: .utf8) else { return [] }

        var items: [NetworkFileItem] = []
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)

        // Skip header
        for line in lines.dropFirst() {
            let parts = String(line).split(separator: ",", maxSplits: 3)
            guard parts.count == 4 else { continue }

            let path = String(parts[0])
                .replacingOccurrences(of: "\\,", with: ",")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")

            guard let size = Int64(parts[1]),
                  let mtime = Int64(parts[3]) else { continue }

            items.append(NetworkFileItem(
                path: path,
                size: size,
                hash: String(parts[2]),
                mtime: mtime
            ))
        }

        return items
    }
}

#if canImport(Compression)
// MARK: - File Payload Encoding

/// Encodes/decodes file data payloads with optional compression
///
/// Payload format: `<path>\t<compressed:0|1>\t<original_size>\n<data>`
public struct FilePayload {
    public let path: String
    public let data: Data
    public let isCompressed: Bool
    public let originalSize: Int

    public init(path: String, data: Data, isCompressed: Bool = false, originalSize: Int? = nil) {
        self.path = path
        self.data = data
        self.isCompressed = isCompressed
        self.originalSize = originalSize ?? data.count
    }

    /// Encode payload for transmission
    public func encode() -> Data {
        var payload = Data()
        let header = "\(path)\t\(isCompressed ? 1 : 0)\t\(originalSize)\n"
        payload.append(header.data(using: .utf8)!)
        payload.append(data)
        return payload
    }

    /// Decode payload from received data
    public static func decode(_ payload: Data) -> FilePayload? {
        guard let newlineIndex = payload.firstIndex(of: 0x0A) else {
            return nil
        }

        let headerData = payload[..<newlineIndex]
        let fileData = payload[payload.index(after: newlineIndex)...]

        guard let header = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let parts = header.split(separator: "\t", omittingEmptySubsequences: false)

        // Support both old format (path only) and new format (path, compressed, originalSize)
        if parts.count == 1 {
            // Old format: just path
            return FilePayload(path: String(parts[0]), data: Data(fileData))
        } else if parts.count >= 3 {
            // New format: path\tcompressed\toriginalSize
            let path = String(parts[0])
            let isCompressed = parts[1] == "1"
            let originalSize = Int(parts[2]) ?? fileData.count
            return FilePayload(path: path, data: Data(fileData), isCompressed: isCompressed, originalSize: originalSize)
        }

        return nil
    }

    /// Create payload with automatic compression decision
    public static func create(path: String, data: Data) -> FilePayload {
        // Check if we should compress
        if SyncCompression.shouldCompress(path: path, size: data.count) {
            if let compressed = SyncCompression.compress(data) {
                return FilePayload(path: path, data: compressed, isCompressed: true, originalSize: data.count)
            }
        }
        // Return uncompressed
        return FilePayload(path: path, data: data, isCompressed: false, originalSize: data.count)
    }

    /// Get decompressed data
    public func decompressedData() -> Data? {
        if isCompressed {
            return SyncCompression.decompress(data, originalSize: originalSize)
        }
        return data
    }
}

#endif // canImport(Compression)

// MARK: - Errors

public enum SyncProtocolError: Error, CustomStringConvertible {
    case invalidHeader
    case incompletePayload
    case unexpectedMessage(expected: SyncMessageType, got: SyncMessageType)
    case serverError(message: String)
    case connectionFailed(host: String, port: Int)
    case timeout

    public var description: String {
        switch self {
        case .invalidHeader:
            return "Invalid message header"
        case .incompletePayload:
            return "Incomplete message payload"
        case .unexpectedMessage(let expected, let got):
            return "Expected \(expected.rawValue), got \(got.rawValue)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .connectionFailed(let host, let port):
            return "Connection failed: \(host):\(port)"
        case .timeout:
            return "Connection timeout"
        }
    }
}
