import Foundation

/// Network protocol messages for EfficientSync (wire framing v2)
///
/// **Protocol Overview:**
/// 1. Client connects to server
/// 2. Client sends HELLO — `<magic><protocol-major><mode>` (version gate)
/// 3. Server sends OK (or ERROR on version/magic mismatch)
/// 4. Client sends snapshot metadata (typed binary records)
/// 5. Server sends snapshot metadata
/// 6. Both compute operations locally
/// 7. File transfer phase (requester asks for files)
/// 8. DONE message ends session
///
/// **Message envelope:** `<TYPE> <LENGTH>\n` header + `<LENGTH bytes>` body.
/// Declared LENGTH is capped per message type and the body is read in a
/// loop (a single socket read may return short).
///
/// **Metadata records (framing v2):** length-prefixed, typed, counted —
/// replaces the v1 CSV, which dropped the whole listing on one invalid
/// UTF-8 byte and mis-split escaped commas. Paths are counted opaque
/// components (no delimiter join, so `/` vs `\` never matters); hashes are
/// raw bytes. `mtime`, `is_folder`, `permissions` are **reserved** — carried
/// now, ignored by the phase-1 comparator, so phase 2 doesn't re-break the
/// wire.

public enum SyncMessageType: String {
    case hello = "HELLO"
    case ok = "OK"
    case error = "ERROR"
    case metadata = "METADATA"
    case requestFile = "REQUEST"
    case fileData = "FILE"
    case deleteFile = "DELETE"
    case copyFile = "COPY"
    case done = "DONE"
}

/// Sync mode for network protocol
public enum NetworkSyncMode: String {
    case push = "PUSH"   // Client → Server
    case pull = "PULL"   // Server → Client
}

// MARK: - Protocol version & limits

/// Wire protocol identity. Framing v2 prefixes HELLO with these so a
/// mismatched or non-Diffa peer is rejected before any mode/auth parsing.
/// A major mismatch is a hard, non-negotiated break (pre-1.0: all peers
/// rebuild from source).
public enum NetworkProtocol {
    /// "DIFA" — also sheds random port-scan / wrong-protocol traffic.
    public static let magic: [UInt8] = [0x44, 0x49, 0x46, 0x41]
    public static let major: UInt32 = 2

    /// Build the HELLO payload: `<magic><major><mode>`.
    public static func encodeHello(mode: NetworkSyncMode) -> Data {
        var d = Data(magic)
        appendU32(major, to: &d)
        d.append(Data(mode.rawValue.utf8))
        return d
    }

    /// Parse a HELLO payload, rejecting magic/version mismatch first.
    public static func decodeHello(_ payload: Data) throws -> NetworkSyncMode {
        var r = ByteReader(payload)
        let m = try r.readBytes(4, cap: 4)
        guard m == magic else {
            throw SyncProtocolError.incompatibleProtocol(reason: "not a Diffa peer")
        }
        let peerMajor = try r.readU32()
        guard peerMajor == major else {
            throw SyncProtocolError.incompatibleProtocol(
                reason: "protocol v\(peerMajor), this peer speaks v\(major)")
        }
        let modeBytes = try r.readBytes(UInt32(r.remainingCount), cap: 16)
        guard let s = String(bytes: modeBytes, encoding: .utf8),
              let mode = NetworkSyncMode(rawValue: s) else {
            throw SyncProtocolError.invalidHeader
        }
        return mode
    }
}

/// Hard bounds for the (pre-auth) parser. A declared length over its cap is
/// rejected *before* allocating, so a hostile header can't drive a big alloc.
public enum NetworkProtocolLimits {
    public static let maxHeaderLength = 256
    public static let maxControlPayload = 64 * 1024          // HELLO/OK/ERROR/REQUEST/…
    public static let maxMetadataPayload = 1 << 30           // 1 GiB listing
    public static let maxFilePayload = 2 << 30               // 2 GiB file chunk
    public static let maxRecordCount: UInt32 = 5_000_000
    public static let maxPathComponents: UInt32 = 1024
    public static let maxComponentLength: UInt32 = 4096
    public static let maxHashLength: UInt32 = 64
}

/// Per-type envelope payload cap.
func maxPayloadLength(for type: SyncMessageType) -> Int {
    switch type {
    case .metadata: return NetworkProtocolLimits.maxMetadataPayload
    case .fileData: return NetworkProtocolLimits.maxFilePayload
    default: return NetworkProtocolLimits.maxControlPayload
    }
}

// MARK: - Big-endian write helpers

func appendU32(_ v: UInt32, to data: inout Data) {
    data.append(UInt8((v >> 24) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF))
    data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8(v & 0xFF))
}

func appendU64(_ v: UInt64, to data: inout Data) {
    var shift = 56
    while shift >= 0 {
        data.append(UInt8((v >> UInt64(shift)) & 0xFF))
        shift -= 8
    }
}

/// Bounded, big-endian reader. Every read is length-checked against the
/// remaining bytes, and length-prefixed blobs are checked against a cap
/// before the bounds check — so an over-cap or over-read throws instead of
/// allocating or trapping. Indexes relative to `startIndex` (no copy).
struct ByteReader {
    private let data: Data
    private let base: Int
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.base = data.startIndex
        self.offset = 0
    }

    var remainingCount: Int { data.endIndex - (base + offset) }
    var isAtEnd: Bool { remainingCount <= 0 }

    private func require(_ n: Int) throws {
        guard n >= 0, n <= remainingCount else { throw SyncProtocolError.invalidMetadata }
    }

    mutating func readU8() throws -> UInt8 {
        try require(1)
        let v = data[base + offset]
        offset += 1
        return v
    }

    mutating func readU32() throws -> UInt32 {
        try require(4)
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[base + offset + i]) }
        offset += 4
        return v
    }

    mutating func readU64() throws -> UInt64 {
        try require(8)
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[base + offset + i]) }
        offset += 8
        return v
    }

    /// Read `len` bytes, rejecting `len > cap` before the bounds/alloc.
    mutating func readBytes(_ len: UInt32, cap: UInt32) throws -> [UInt8] {
        guard len <= cap else { throw SyncProtocolError.invalidMetadata }
        let n = Int(len)
        try require(n)
        let start = base + offset
        let bytes = Array(data[start..<start + n])
        offset += n
        return bytes
    }
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
        // Read header line, bounded so a peer that never sends a newline
        // can't drive an unbounded read.
        var headerBytes: [UInt8] = []
        var byte: UInt8 = 0
        while stream.read(&byte, maxLength: 1) == 1 {
            if byte == 0x0A { break } // newline
            headerBytes.append(byte)
            if headerBytes.count > NetworkProtocolLimits.maxHeaderLength {
                throw SyncProtocolError.invalidHeader
            }
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

        // Reject an over-cap or negative declared length before allocating.
        guard length >= 0, length <= maxPayloadLength(for: type) else {
            throw SyncProtocolError.payloadTooLarge(type: type.rawValue, length: length)
        }

        // Read the payload in a loop — a single socket read may return short.
        var payload = Data(count: length)
        if length > 0 {
            var total = 0
            payload.withUnsafeMutableBytes { buffer in
                let base = buffer.bindMemory(to: UInt8.self).baseAddress!
                while total < length {
                    let n = stream.read(base + total, maxLength: length - total)
                    if n <= 0 { break }
                    total += n
                }
            }
            guard total == length else {
                throw SyncProtocolError.incompletePayload
            }
        }

        return SyncMessage(type: type, payload: payload)
    }
}

// MARK: - Metadata Encoding (framing v2)

/// File metadata for network transfer.
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
        return FileItem(path: path, size: size, hash: Self.hexToBytes(hash), mtime: mtime, mode: nil)
    }

    // MARK: hex helpers

    static func hexToBytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: min($0 + 2, hex.count))], radix: 16)
        })
    }

    static func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Encode a listing to the framing-v2 binary format:
    /// `[count u32]` then per record `[componentCount u32]
    /// (len u32 + raw bytes)… [size u64] [hashLen u32 + raw] [mtime u64]
    /// [is_folder u8] [permissions u32]`.
    public static func encode(_ items: [NetworkFileItem]) -> Data {
        var data = Data()
        appendU32(UInt32(truncatingIfNeeded: items.count), to: &data)
        for item in items {
            let components = item.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            appendU32(UInt32(truncatingIfNeeded: components.count), to: &data)
            for component in components {
                let bytes = Array(component.utf8)
                appendU32(UInt32(truncatingIfNeeded: bytes.count), to: &data)
                data.append(contentsOf: bytes)
            }
            appendU64(UInt64(bitPattern: item.size), to: &data)
            let hashBytes = Array(hexToBytes(item.hash))
            appendU32(UInt32(truncatingIfNeeded: hashBytes.count), to: &data)
            data.append(contentsOf: hashBytes)
            appendU64(UInt64(bitPattern: item.mtime), to: &data)  // reserved
            data.append(0)                                        // reserved is_folder
            appendU32(0, to: &data)                               // reserved permissions
        }
        return data
    }

    /// Decode a framing-v2 listing. Throws on any structural violation
    /// (over-cap counts/lengths, over-read, trailing data, invalid path
    /// component). A single bad record fails the whole message rather than
    /// silently emptying the listing (the v1 CSV failure mode).
    public static func decode(_ data: Data) throws -> [NetworkFileItem] {
        var r = ByteReader(data)
        let count = try r.readU32()
        guard count <= NetworkProtocolLimits.maxRecordCount else {
            throw SyncProtocolError.invalidMetadata
        }
        var items: [NetworkFileItem] = []
        for _ in 0..<count {
            let componentCount = try r.readU32()
            guard componentCount <= NetworkProtocolLimits.maxPathComponents, componentCount > 0 else {
                throw SyncProtocolError.invalidMetadata
            }
            var components: [String] = []
            for _ in 0..<componentCount {
                let len = try r.readU32()
                let bytes = try r.readBytes(len, cap: NetworkProtocolLimits.maxComponentLength)
                guard let component = String(bytes: bytes, encoding: .utf8) else {
                    throw SyncProtocolError.invalidMetadata
                }
                // Path validation — reject even in read-only.
                guard !component.isEmpty, component != ".", component != "..",
                      !component.contains("\0") else {
                    throw SyncProtocolError.invalidMetadata
                }
                components.append(component)
            }
            let path = components.joined(separator: "/")
            let size = Int64(bitPattern: try r.readU64())
            let hashLen = try r.readU32()
            let hashBytes = try r.readBytes(hashLen, cap: NetworkProtocolLimits.maxHashLength)
            let mtime = Int64(bitPattern: try r.readU64())  // reserved
            _ = try r.readU8()                              // reserved is_folder
            _ = try r.readU32()                             // reserved permissions
            items.append(NetworkFileItem(
                path: path, size: size, hash: bytesToHex(hashBytes), mtime: mtime))
        }
        guard r.isAtEnd else { throw SyncProtocolError.invalidMetadata }  // reject trailing data
        return items
    }
}

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

// MARK: - Errors

public enum SyncProtocolError: Error, CustomStringConvertible {
    case invalidHeader
    case incompletePayload
    case payloadTooLarge(type: String, length: Int)
    case incompatibleProtocol(reason: String)
    case invalidMetadata
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
        case .payloadTooLarge(let type, let length):
            return "Payload too large for \(type): \(length) bytes"
        case .incompatibleProtocol(let reason):
            return "Incompatible protocol: \(reason)"
        case .invalidMetadata:
            return "Invalid metadata framing"
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
