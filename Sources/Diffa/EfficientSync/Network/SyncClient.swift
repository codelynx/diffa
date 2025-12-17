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
        log("Connecting to \(host):\(port)...")

        // Create connection
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)

        let semaphore = DispatchSemaphore(value: 0)
        var connectionError: Error?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                connectionError = error
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: .global())
        semaphore.wait()

        if let error = connectionError {
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
            // Note: server-side deletions handled by server

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
                log("Deleting: \(path)")

                let fileURL = localPath.appendingPathComponent(path)
                try? FileManager.default.removeItem(at: fileURL)
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

    private func receiveMessageSync(_ connection: NWConnection) throws -> SyncMessage {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<SyncMessage, Error>?

        // Read up to 10MB at a time
        connection.receive(minimumIncompleteLength: 1, maximumLength: 10 * 1024 * 1024) { data, _, _, error in
            if let error = error {
                result = .failure(error)
                semaphore.signal()
                return
            }

            guard let data = data, !data.isEmpty else {
                result = .failure(SyncProtocolError.incompletePayload)
                semaphore.signal()
                return
            }

            // Parse header
            guard let headerEnd = data.firstIndex(of: 0x0A) else {
                result = .failure(SyncProtocolError.invalidHeader)
                semaphore.signal()
                return
            }

            let headerData = data[..<headerEnd]
            guard let header = String(data: headerData, encoding: .utf8) else {
                result = .failure(SyncProtocolError.invalidHeader)
                semaphore.signal()
                return
            }

            let parts = header.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let type = SyncMessageType(rawValue: String(parts[0])),
                  let length = Int(parts[1]) else {
                result = .failure(SyncProtocolError.invalidHeader)
                semaphore.signal()
                return
            }

            let payloadStart = data.index(after: headerEnd)
            let payload = Data(data[payloadStart...].prefix(length))

            result = .success(SyncMessage(type: type, payload: payload))
            semaphore.signal()
        }

        semaphore.wait()

        switch result {
        case .success(let message):
            return message
        case .failure(let error):
            throw error
        case .none:
            throw SyncProtocolError.timeout
        }
    }

    private func log(_ message: String) {
        onLog?(message)
        print(message)
    }
}
