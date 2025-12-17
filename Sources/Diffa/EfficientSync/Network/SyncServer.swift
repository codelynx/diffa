import Foundation
#if canImport(Network)
import Network
#endif

/// TCP server for EfficientSync daemon
///
/// **Usage:**
/// ```swift
/// let server = SyncServer(path: URL(fileURLWithPath: "/data"), port: 8080)
/// try await server.start()
/// // Server runs until stopped
/// server.stop()
/// ```
@available(macOS 10.14, *)
public final class SyncServer {
    private let rootPath: URL
    private let port: UInt16
    private var listener: NWListener?
    private var isRunning = false

    /// Callback for logging
    public var onLog: ((String) -> Void)?

    public init(path: URL, port: UInt16) {
        self.rootPath = path
        self.port = port
    }

    /// Start server (blocking)
    public func start() throws {
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("Server listening on port \(self?.port ?? 0)")
                self?.log("Serving: \(self?.rootPath.path ?? "")")
            case .failed(let error):
                self?.log("Server failed: \(error)")
            case .cancelled:
                self?.log("Server stopped")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global())
        isRunning = true

        // Keep running
        log("Press Ctrl+C to stop")
        dispatchMain()
    }

    /// Stop server
    public func stop() {
        listener?.cancel()
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let clientEndpoint = connection.endpoint
        log("Client connected: \(clientEndpoint)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.processClient(connection)
            case .failed(let error):
                self?.log("Connection failed: \(error)")
            case .cancelled:
                self?.log("Client disconnected: \(clientEndpoint)")
            default:
                break
            }
        }

        connection.start(queue: .global())
    }

    private func processClient(_ connection: NWConnection) {
        // Read HELLO message
        receiveMessage(connection) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                guard message.type == .hello else {
                    self.sendError(connection, "Expected HELLO")
                    return
                }

                let modeString = String(data: message.payload, encoding: .utf8) ?? ""
                guard let mode = NetworkSyncMode(rawValue: modeString) else {
                    self.sendError(connection, "Invalid mode: \(modeString)")
                    return
                }

                self.log("Mode: \(mode.rawValue)")

                // Send OK
                self.sendMessage(connection, SyncMessage(type: .ok)) {
                    self.handleSync(connection, mode: mode)
                }

            case .failure(let error):
                self.log("Error reading HELLO: \(error)")
                connection.cancel()
            }
        }
    }

    private func handleSync(_ connection: NWConnection, mode: NetworkSyncMode) {
        // Create local snapshot
        log("Creating snapshot...")
        guard let snapshot = try? SQLiteSyncSnapshot.create(at: rootPath) else {
            sendError(connection, "Failed to create snapshot")
            return
        }

        let localItems = snapshot.allFiles().map { NetworkFileItem(from: $0) }
        log("Local files: \(localItems.count)")

        // Receive client metadata
        receiveMessage(connection) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                guard message.type == .metadata else {
                    self.sendError(connection, "Expected METADATA")
                    return
                }

                let remoteItems = NetworkFileItem.decodeCSV(message.payload)
                self.log("Remote files: \(remoteItems.count)")

                // Send local metadata
                let localCSV = NetworkFileItem.encodeCSV(localItems)
                self.sendMessage(connection, SyncMessage(type: .metadata, payload: localCSV)) {
                    // Handle file transfers based on mode
                    self.handleFileTransfers(connection, mode: mode, localItems: localItems, remoteItems: remoteItems, snapshot: snapshot)
                }

            case .failure(let error):
                self.log("Error reading METADATA: \(error)")
                connection.cancel()
            }
        }
    }

    private func handleFileTransfers(
        _ connection: NWConnection,
        mode: NetworkSyncMode,
        localItems: [NetworkFileItem],
        remoteItems: [NetworkFileItem],
        snapshot: SQLiteSyncSnapshot
    ) {
        // Wait for file requests or DONE
        receiveMessage(connection) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message.type {
                case .requestFile:
                    // Client requesting a file from us
                    let path = String(data: message.payload, encoding: .utf8) ?? ""
                    self.sendFile(connection, path: path) {
                        // Continue waiting for more requests
                        self.handleFileTransfers(connection, mode: mode, localItems: localItems, remoteItems: remoteItems, snapshot: snapshot)
                    }

                case .fileData:
                    // Client sending us a file (push mode)
                    self.receiveFile(connection, data: message.payload) {
                        self.handleFileTransfers(connection, mode: mode, localItems: localItems, remoteItems: remoteItems, snapshot: snapshot)
                    }

                case .done:
                    self.log("Sync complete")
                    self.sendMessage(connection, SyncMessage(type: .done)) {
                        connection.cancel()
                    }

                default:
                    self.sendError(connection, "Unexpected message: \(message.type.rawValue)")
                }

            case .failure(let error):
                self.log("Error: \(error)")
                connection.cancel()
            }
        }
    }

    private func sendFile(_ connection: NWConnection, path: String, completion: @escaping () -> Void) {
        let fileURL = rootPath.appendingPathComponent(path)

        guard let data = try? Data(contentsOf: fileURL) else {
            sendError(connection, "File not found: \(path)")
            return
        }

        // Format: path\n<data>
        var payload = Data()
        payload.append((path + "\n").data(using: .utf8)!)
        payload.append(data)

        log("Sending file: \(path) (\(data.count) bytes)")
        sendMessage(connection, SyncMessage(type: .fileData, payload: payload), completion: completion)
    }

    private func receiveFile(_ connection: NWConnection, data: Data, completion: @escaping () -> Void) {
        // Parse: path\n<data>
        guard let newlineIndex = data.firstIndex(of: 0x0A) else {
            log("Invalid file data")
            completion()
            return
        }

        let pathData = data[..<newlineIndex]
        let fileData = data[data.index(after: newlineIndex)...]

        guard let path = String(data: pathData, encoding: .utf8) else {
            log("Invalid file path")
            completion()
            return
        }

        let fileURL = rootPath.appendingPathComponent(path)

        // Create parent directories
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write file
        do {
            try Data(fileData).write(to: fileURL)
            log("Received file: \(path) (\(fileData.count) bytes)")
        } catch {
            log("Failed to write file: \(error)")
        }

        completion()
    }

    // MARK: - Network Helpers

    private func sendMessage(_ connection: NWConnection, _ message: SyncMessage, completion: @escaping () -> Void = {}) {
        connection.send(content: message.encode(), completion: .contentProcessed { _ in
            completion()
        })
    }

    private func sendError(_ connection: NWConnection, _ message: String) {
        log("Error: \(message)")
        sendMessage(connection, SyncMessage(type: .error, string: message)) {
            connection.cancel()
        }
    }

    private func receiveMessage(_ connection: NWConnection, completion: @escaping (Result<SyncMessage, Error>) -> Void) {
        // Read header (up to newline)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data, !data.isEmpty else {
                completion(.failure(SyncProtocolError.incompletePayload))
                return
            }

            // Parse header
            guard let headerEnd = data.firstIndex(of: 0x0A) else {
                completion(.failure(SyncProtocolError.invalidHeader))
                return
            }

            let headerData = data[..<headerEnd]
            guard let header = String(data: headerData, encoding: .utf8) else {
                completion(.failure(SyncProtocolError.invalidHeader))
                return
            }

            let parts = header.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let type = SyncMessageType(rawValue: String(parts[0])),
                  let length = Int(parts[1]) else {
                completion(.failure(SyncProtocolError.invalidHeader))
                return
            }

            // Get payload (might be partial in first read)
            let payloadStart = data.index(after: headerEnd)
            var payload = Data(data[payloadStart...])

            if payload.count >= length {
                // Complete message
                completion(.success(SyncMessage(type: type, payload: Data(payload.prefix(length)))))
            } else {
                // Need more data
                self?.receiveRemainingPayload(connection, current: payload, total: length) { result in
                    switch result {
                    case .success(let fullPayload):
                        completion(.success(SyncMessage(type: type, payload: fullPayload)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func receiveRemainingPayload(_ connection: NWConnection, current: Data, total: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        let remaining = total - current.count

        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(SyncProtocolError.incompletePayload))
                return
            }

            var payload = current
            payload.append(data)

            if payload.count >= total {
                completion(.success(Data(payload.prefix(total))))
            } else {
                self.receiveRemainingPayload(connection, current: payload, total: total, completion: completion)
            }
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)"
        onLog?(logLine)
        print(logLine)
    }
}
