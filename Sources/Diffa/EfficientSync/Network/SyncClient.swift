import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#else
import Glibc
#endif

/// TCP client for EfficientSync push/pull using cross-platform sockets
///
/// **Usage:**
/// ```swift
/// let client = SyncClient()
/// try client.push(localPath: URL(...), to: "host", port: 8080)
/// // or
/// try client.pull(localPath: URL(...), from: "host", port: 8080)
/// ```
public final class SyncClient {
    /// Callback for logging
    public var onLog: ((String) -> Void)?

    /// Callback for progress
    public var onProgress: ((String, Int, Int) -> Void)?  // (file, current, total)

    public init() {}

    /// Push local files to remote server
    public func push(localPath: URL, to host: String, port: UInt16) throws {
        try sync(localPath: localPath, host: host, port: port, mode: .push)
    }

    /// Pull remote files to local
    public func pull(localPath: URL, from host: String, port: UInt16) throws {
        try sync(localPath: localPath, host: host, port: port, mode: .pull)
    }

    // MARK: - Core Sync

    private func sync(localPath: URL, host: String, port: UInt16, mode: NetworkSyncMode) throws {
        receiveBuffer = Data()
        platformSocketInit()

        log("Connecting to \(host):\(port)...")

        let fd = try connectToHost(host, port: port)
        defer { platformClose(fd) }

        log("Connected!")

        // Send HELLO
        try sendMessageSync(fd, SyncMessage(type: .hello, string: mode.rawValue))

        // Receive OK
        let okMessage = try receiveMessageSync(fd)
        guard okMessage.type == .ok else {
            if okMessage.type == .error {
                throw SyncProtocolError.serverError(message: String(data: okMessage.payload, encoding: .utf8) ?? "Unknown error")
            }
            throw SyncProtocolError.unexpectedMessage(expected: .ok, got: okMessage.type)
        }

        log("Handshake complete")

        // Create local snapshot
        log("Creating local snapshot...")
        let localSnapshot = try SQLiteSyncSnapshot.create(at: localPath)
        let localItems = localSnapshot.allFiles().map { NetworkFileItem(from: $0) }
        log("Local files: \(localItems.count)")

        // Send local metadata
        let localCSV = NetworkFileItem.encodeCSV(localItems)
        try sendMessageSync(fd, SyncMessage(type: .metadata, payload: localCSV))

        // Receive remote metadata
        let metadataMessage = try receiveMessageSync(fd)
        guard metadataMessage.type == .metadata else {
            throw SyncProtocolError.unexpectedMessage(expected: .metadata, got: metadataMessage.type)
        }

        let remoteItems = NetworkFileItem.decodeCSV(metadataMessage.payload)
        log("Remote files: \(remoteItems.count)")

        // Compute operations
        let operations = computeOperations(localItems: localItems, remoteItems: remoteItems, mode: mode)
        log("Operations: \(operations.count)")

        // Execute file transfers
        try executeTransfers(fd, localPath: localPath, operations: operations, mode: mode)

        // Send DONE
        try sendMessageSync(fd, SyncMessage(type: .done))

        // Wait for server DONE
        let doneMessage = try receiveMessageSync(fd)
        if doneMessage.type != .done {
            log("Warning: Expected DONE, got \(doneMessage.type.rawValue)")
        }

        log("Sync complete!")
    }

    // MARK: - Connection

    private func connectToHost(_ host: String, port: UInt16) throws -> SocketDescriptor {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = platformStreamType

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = getaddrinfo(host, portString, &hints, &result)
        guard status == 0, let addrInfo = result else {
            throw SyncProtocolError.connectionFailed(host: host, port: Int(port))
        }
        defer { freeaddrinfo(result) }

        let fd = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
        guard platformIsValidSocket(fd) else {
            throw SyncProtocolError.connectionFailed(host: host, port: Int(port))
        }

        // Non-blocking connect with 10-second timeout
        platformSetNonBlocking(fd, true)

        #if os(Windows)
        let connectResult = connect(fd, addrInfo.pointee.ai_addr, Int32(addrInfo.pointee.ai_addrlen))
        #else
        let connectResult = connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)
        #endif

        if connectResult != 0 {
            let err = platformSocketError()
            guard platformIsErrorInProgress(err) else {
                platformClose(fd)
                throw SyncProtocolError.connectionFailed(host: host, port: Int(port))
            }

            // Wait for connection with poll()
            var pfds = [makePollfd(fd: fd, events: Int16(POLLOUT))]
            let pollResult = platformPoll(&pfds, 1, 10_000)  // 10 second timeout

            guard pollResult > 0 else {
                platformClose(fd)
                throw SyncProtocolError.timeout
            }

            // Check for connection error
            let connectError = platformGetSocketError(fd)

            guard connectError == 0 else {
                platformClose(fd)
                throw SyncProtocolError.connectionFailed(host: host, port: Int(port))
            }
        }

        // Set back to blocking mode
        platformSetNonBlocking(fd, false)

        // Set timeouts
        platformSetSocketTimeouts(fd, seconds: 30)

        // Prevent SIGPIPE (macOS only; Linux handled per-send; Windows N/A)
        platformSetNoSigPipe(fd)

        return fd
    }

    // MARK: - Operations

    private struct TransferOperation {
        enum Action {
            case download(path: String)
            case upload(path: String)
            case delete(path: String)
        }
        let action: Action
    }

    private func computeOperations(
        localItems: [NetworkFileItem],
        remoteItems: [NetworkFileItem],
        mode: NetworkSyncMode
    ) -> [TransferOperation] {
        var operations: [TransferOperation] = []

        let localByPath = Dictionary(uniqueKeysWithValues: localItems.map { ($0.path, $0) })
        let remoteByPath = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.path, $0) })

        switch mode {
        case .push:
            for (path, localItem) in localByPath {
                if let remoteItem = remoteByPath[path] {
                    if localItem.hash != remoteItem.hash {
                        operations.append(TransferOperation(action: .upload(path: path)))
                    }
                } else {
                    operations.append(TransferOperation(action: .upload(path: path)))
                }
            }
            for path in remoteByPath.keys {
                if localByPath[path] == nil {
                    operations.append(TransferOperation(action: .delete(path: path)))
                }
            }

        case .pull:
            for (path, remoteItem) in remoteByPath {
                if let localItem = localByPath[path] {
                    if remoteItem.hash != localItem.hash {
                        operations.append(TransferOperation(action: .download(path: path)))
                    }
                } else {
                    operations.append(TransferOperation(action: .download(path: path)))
                }
            }
            for path in localByPath.keys {
                if remoteByPath[path] == nil {
                    operations.append(TransferOperation(action: .delete(path: path)))
                }
            }
        }

        return operations
    }

    private func executeTransfers(
        _ fd: SocketDescriptor,
        localPath: URL,
        operations: [TransferOperation],
        mode: NetworkSyncMode
    ) throws {
        var current = 0
        let total = operations.count

        for operation in operations {
            current += 1

            switch operation.action {
            case .download(let path):
                onProgress?(path, current, total)
                log("Downloading: \(path)")

                try sendMessageSync(fd, SyncMessage(type: .requestFile, string: path))

                let fileMessage = try receiveMessageSync(fd)
                guard fileMessage.type == .fileData else {
                    if fileMessage.type == .error {
                        log("Server error: \(String(data: fileMessage.payload, encoding: .utf8) ?? "")")
                        continue
                    }
                    throw SyncProtocolError.unexpectedMessage(expected: .fileData, got: fileMessage.type)
                }

                try writeReceivedFile(fileMessage.payload, to: localPath)

            case .upload(let path):
                onProgress?(path, current, total)

                let fileURL = localPath.appendingPathComponent(path)
                let fileData = try Data(contentsOf: fileURL)

                let filePayload = FilePayload.create(path: path, data: fileData)

                if filePayload.isCompressed {
                    let ratio = 100 - (filePayload.data.count * 100 / fileData.count)
                    log("Uploading: \(path) (\(fileData.count) → \(filePayload.data.count) bytes, \(ratio)% saved)")
                } else {
                    log("Uploading: \(path) (\(fileData.count) bytes)")
                }

                try sendMessageSync(fd, SyncMessage(type: .fileData, payload: filePayload.encode()))

            case .delete(let path):
                onProgress?(path, current, total)

                if mode == .push {
                    log("Deleting (remote): \(path)")
                    try sendMessageSync(fd, SyncMessage(type: .deleteFile, string: path))
                } else {
                    log("Deleting (local): \(path)")
                    let fileURL = localPath.appendingPathComponent(path)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    private func writeReceivedFile(_ data: Data, to localPath: URL) throws {
        guard let filePayload = FilePayload.decode(data) else {
            throw SyncProtocolError.invalidHeader
        }

        guard let fileData = filePayload.decompressedData() else {
            throw SyncProtocolError.incompletePayload
        }

        let fileURL = localPath.appendingPathComponent(filePayload.path)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try fileData.write(to: fileURL)

        if filePayload.isCompressed {
            log("  Written: \(filePayload.path) (\(filePayload.data.count) → \(fileData.count) bytes, decompressed)")
        } else {
            log("  Written: \(filePayload.path) (\(fileData.count) bytes)")
        }
    }

    // MARK: - Network Helpers

    private func sendMessageSync(_ fd: SocketDescriptor, _ message: SyncMessage) throws {
        let data = message.encode()
        try data.withUnsafeBytes { ptr in
            var sent = 0
            let total = data.count
            while sent < total {
                let base = ptr.baseAddress!.advanced(by: sent)
                let n = platformSend(fd, base, total - sent)
                guard n > 0 else {
                    throw SyncProtocolError.incompletePayload
                }
                sent += n
            }
        }
    }

    /// Receive buffer for handling partial reads
    private var receiveBuffer = Data()

    private func receiveMessageSync(_ fd: SocketDescriptor) throws -> SyncMessage {
        if let message = tryParseMessageFromBuffer() {
            return message
        }

        var readBuffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = platformRecv(fd, &readBuffer, readBuffer.count)

            if n == 0 {
                throw SyncProtocolError.incompletePayload
            }
            if n < 0 {
                let err = platformSocketError()
                if platformIsErrorWouldBlock(err) {
                    throw SyncProtocolError.timeout
                }
                throw SyncProtocolError.incompletePayload
            }

            receiveBuffer.append(contentsOf: readBuffer[..<n])

            if let message = tryParseMessageFromBuffer() {
                return message
            }
        }
    }

    private func tryParseMessageFromBuffer() -> SyncMessage? {
        guard let headerEnd = receiveBuffer.firstIndex(of: 0x0A) else {
            return nil
        }

        let headerData = receiveBuffer[..<headerEnd]
        guard let header = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let type = SyncMessageType(rawValue: String(parts[0])),
              let length = Int(parts[1]) else {
            return nil
        }

        let payloadStart = receiveBuffer.index(after: headerEnd)
        let availablePayload = receiveBuffer.count - (payloadStart - receiveBuffer.startIndex)

        guard availablePayload >= length else {
            return nil
        }

        let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: length)
        let payload = Data(receiveBuffer[payloadStart..<payloadEnd])

        receiveBuffer = Data(receiveBuffer[payloadEnd...])

        return SyncMessage(type: type, payload: payload)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
