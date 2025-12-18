import Foundation
#if canImport(Network)
import Network
#endif

/// TCP client for EfficientSync push/pull
///
/// **Usage:**
/// ```swift
/// let client = SyncClient()
/// try await client.push(localPath: URL(...), to: "host", port: 8080)
/// // or
/// try await client.pull(localPath: URL(...), from: "host", port: 8080)
/// ```
@available(macOS 10.14, *)
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
        // Reset receive buffer for new sync
        receiveBuffer = Data()

        log("Connecting to \(host):\(port)...")

        // Create connection
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)

        let semaphore = DispatchSemaphore(value: 0)
        var connectionError: Error?

        connection.stateUpdateHandler = { [weak self] state in
            self?.log("Connection state: \(state)")
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                connectionError = error
                semaphore.signal()
            case .waiting(let error):
                self?.log("Waiting: \(error)")
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        log("Starting connection...")
        connection.start(queue: .global())

        log("Waiting for connection...")
        let timeout = DispatchTime.now() + .seconds(10)
        if semaphore.wait(timeout: timeout) == .timedOut {
            connection.cancel()
            throw SyncProtocolError.timeout
        }

        if let error = connectionError {
            log("Connection error: \(error)")
            throw SyncProtocolError.connectionFailed(host: host, port: Int(port))
        }

        log("Connected!")

        defer { connection.cancel() }

        // Send HELLO
        sendMessageSync(connection, SyncMessage(type: .hello, string: mode.rawValue))

        // Receive OK
        let okMessage = try receiveMessageSync(connection)
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
        sendMessageSync(connection, SyncMessage(type: .metadata, payload: localCSV))

        // Receive remote metadata
        let metadataMessage = try receiveMessageSync(connection)
        guard metadataMessage.type == .metadata else {
            throw SyncProtocolError.unexpectedMessage(expected: .metadata, got: metadataMessage.type)
        }

        let remoteItems = NetworkFileItem.decodeCSV(metadataMessage.payload)
        log("Remote files: \(remoteItems.count)")

        // Compute operations
        let operations = computeOperations(localItems: localItems, remoteItems: remoteItems, mode: mode)
        log("Operations: \(operations.count)")

        // Execute file transfers
        try executeTransfers(connection, localPath: localPath, operations: operations, mode: mode)

        // Send DONE
        sendMessageSync(connection, SyncMessage(type: .done))

        // Wait for server DONE
        let doneMessage = try receiveMessageSync(connection)
        if doneMessage.type != .done {
            log("Warning: Expected DONE, got \(doneMessage.type.rawValue)")
        }

        log("Sync complete!")
    }

    // MARK: - Operations

    private struct TransferOperation {
        enum Action {
            case download(path: String)  // Get from server
            case upload(path: String)    // Send to server
            case delete(path: String)    // Delete local
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
            // Push: remote should mirror local
            // Upload files that are new or different on local
            for (path, localItem) in localByPath {
                if let remoteItem = remoteByPath[path] {
                    if localItem.hash != remoteItem.hash {
                        operations.append(TransferOperation(action: .upload(path: path)))
                    }
                } else {
                    operations.append(TransferOperation(action: .upload(path: path)))
                }
            }
            // Delete remote files not on local
            for path in remoteByPath.keys {
                if localByPath[path] == nil {
                    operations.append(TransferOperation(action: .delete(path: path)))
                }
            }

        case .pull:
            // Pull: local should mirror remote
            // Download files that are new or different on remote
            for (path, remoteItem) in remoteByPath {
                if let localItem = localByPath[path] {
                    if remoteItem.hash != localItem.hash {
                        operations.append(TransferOperation(action: .download(path: path)))
                    }
                } else {
                    operations.append(TransferOperation(action: .download(path: path)))
                }
            }
            // Delete local files not on remote
            for path in localByPath.keys {
                if remoteByPath[path] == nil {
                    operations.append(TransferOperation(action: .delete(path: path)))
                }
            }
        }

        return operations
    }

    private func executeTransfers(
        _ connection: NWConnection,
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

                // Request file from server
                sendMessageSync(connection, SyncMessage(type: .requestFile, string: path))

                // Receive file data
                let fileMessage = try receiveMessageSync(connection)
                guard fileMessage.type == .fileData else {
                    if fileMessage.type == .error {
                        log("Server error: \(String(data: fileMessage.payload, encoding: .utf8) ?? "")")
                        continue
                    }
                    throw SyncProtocolError.unexpectedMessage(expected: .fileData, got: fileMessage.type)
                }

                // Parse and write file
                try writeReceivedFile(fileMessage.payload, to: localPath)

            case .upload(let path):
                onProgress?(path, current, total)
                log("Uploading: \(path)")

                // Read local file
                let fileURL = localPath.appendingPathComponent(path)
                let fileData = try Data(contentsOf: fileURL)

                // Send file
                var payload = Data()
                payload.append((path + "\n").data(using: .utf8)!)
                payload.append(fileData)
                sendMessageSync(connection, SyncMessage(type: .fileData, payload: payload))

            case .delete(let path):
                onProgress?(path, current, total)

                if mode == .push {
                    // Push mode: request server to delete remote file
                    log("Deleting (remote): \(path)")
                    sendMessageSync(connection, SyncMessage(type: .deleteFile, string: path))
                } else {
                    // Pull mode: delete local file
                    log("Deleting (local): \(path)")
                    let fileURL = localPath.appendingPathComponent(path)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    private func writeReceivedFile(_ data: Data, to localPath: URL) throws {
        // Parse: path\n<data>
        guard let newlineIndex = data.firstIndex(of: 0x0A) else {
            throw SyncProtocolError.invalidHeader
        }

        let pathData = data[..<newlineIndex]
        let fileData = data[data.index(after: newlineIndex)...]

        guard let path = String(data: pathData, encoding: .utf8) else {
            throw SyncProtocolError.invalidHeader
        }

        let fileURL = localPath.appendingPathComponent(path)

        // Create parent directories
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write file
        try Data(fileData).write(to: fileURL)
        log("  Written: \(path) (\(fileData.count) bytes)")
    }

    // MARK: - Network Helpers

    private func sendMessageSync(_ connection: NWConnection, _ message: SyncMessage) {
        let semaphore = DispatchSemaphore(value: 0)

        connection.send(content: message.encode(), completion: .contentProcessed { _ in
            semaphore.signal()
        })

        semaphore.wait()
    }

    /// Receive buffer for handling partial reads
    private var receiveBuffer = Data()

    private func receiveMessageSync(_ connection: NWConnection) throws -> SyncMessage {
        // Try to parse from existing buffer first
        if let message = tryParseMessageFromBuffer() {
            return message
        }

        // Need to read more data
        while true {
            let semaphore = DispatchSemaphore(value: 0)
            var readResult: Result<Data, Error>?

            // Read more data (up to 64KB at a time)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error = error {
                    readResult = .failure(error)
                } else if let data = data, !data.isEmpty {
                    readResult = .success(data)
                } else {
                    readResult = .failure(SyncProtocolError.incompletePayload)
                }
                semaphore.signal()
            }

            let timeout = DispatchTime.now() + .seconds(30)
            if semaphore.wait(timeout: timeout) == .timedOut {
                throw SyncProtocolError.timeout
            }

            switch readResult {
            case .success(let data):
                receiveBuffer.append(data)
            case .failure(let error):
                throw error
            case .none:
                throw SyncProtocolError.timeout
            }

            // Try to parse again
            if let message = tryParseMessageFromBuffer() {
                return message
            }
            // Loop to read more
        }
    }

    private func tryParseMessageFromBuffer() -> SyncMessage? {
        // Find header end (newline)
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
            return nil  // Not enough payload data yet
        }

        // Extract payload
        let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: length)
        let payload = Data(receiveBuffer[payloadStart..<payloadEnd])

        // Remove consumed data from buffer
        receiveBuffer = Data(receiveBuffer[payloadEnd...])

        return SyncMessage(type: type, payload: payload)
    }

    private func log(_ message: String) {
        onLog?(message)
        print(message)
    }
}
