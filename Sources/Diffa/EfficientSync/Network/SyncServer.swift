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

    /// Per-connection receive buffers (keyed by connection object identifier)
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]
    private let bufferLock = NSLock()

    /// Callback for logging
    public var onLog: ((String) -> Void)?

    public init(path: URL, port: UInt16) {
        self.rootPath = path
        self.port = port
    }

    /// Start server (blocking)
    public func start() throws {
        try startAsync()
        // Keep running
        log("Press Ctrl+C to stop")
        dispatchMain()
    }

    /// Start server (non-blocking, for testing)
    public func startAsync() throws {
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.printServerInfo()
                semaphore.signal()
            case .failed(let error):
                self?.log("Server failed: \(error)")
                startError = error
                semaphore.signal()
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

        // Wait for server to be ready
        _ = semaphore.wait(timeout: .now() + 5)

        if let error = startError {
            throw error
        }

        isRunning = true
    }

    /// Stop server
    public func stop() {
        listener?.cancel()
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let clientEndpoint = connection.endpoint
        let connectionId = ObjectIdentifier(connection)
        log("Client connected: \(clientEndpoint)")

        // Initialize buffer for this connection
        bufferLock.lock()
        connectionBuffers[connectionId] = Data()
        bufferLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.processClient(connection)
            case .failed(let error):
                self?.log("Connection failed: \(error)")
                self?.cleanupConnection(connectionId)
            case .cancelled:
                self?.log("Client disconnected: \(clientEndpoint)")
                self?.cleanupConnection(connectionId)
            default:
                break
            }
        }

        connection.start(queue: .global())
    }

    private func cleanupConnection(_ connectionId: ObjectIdentifier) {
        bufferLock.lock()
        connectionBuffers.removeValue(forKey: connectionId)
        bufferLock.unlock()
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

                case .deleteFile:
                    // Client requesting us to delete a file (push mode)
                    let path = String(data: message.payload, encoding: .utf8) ?? ""
                    self.deleteFile(path: path)
                    self.handleFileTransfers(connection, mode: mode, localItems: localItems, remoteItems: remoteItems, snapshot: snapshot)

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

        // Create payload with automatic compression
        let filePayload = FilePayload.create(path: path, data: data)

        if filePayload.isCompressed {
            let ratio = 100 - (filePayload.data.count * 100 / data.count)
            log("Sending file: \(path) (\(data.count) → \(filePayload.data.count) bytes, \(ratio)% saved)")
        } else {
            log("Sending file: \(path) (\(data.count) bytes)")
        }

        sendMessage(connection, SyncMessage(type: .fileData, payload: filePayload.encode()), completion: completion)
    }

    private func receiveFile(_ connection: NWConnection, data: Data, completion: @escaping () -> Void) {
        // Parse payload (supports both old and new format with compression)
        guard let filePayload = FilePayload.decode(data) else {
            log("Invalid file data")
            completion()
            return
        }

        // Decompress if needed
        guard let fileData = filePayload.decompressedData() else {
            log("Failed to decompress file: \(filePayload.path)")
            completion()
            return
        }

        let fileURL = rootPath.appendingPathComponent(filePayload.path)

        // Create parent directories
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write file
        do {
            try fileData.write(to: fileURL)
            if filePayload.isCompressed {
                log("Received file: \(filePayload.path) (\(filePayload.data.count) → \(fileData.count) bytes, decompressed)")
            } else {
                log("Received file: \(filePayload.path) (\(fileData.count) bytes)")
            }
        } catch {
            log("Failed to write file: \(error)")
        }

        completion()
    }

    private func deleteFile(path: String) {
        let fileURL = rootPath.appendingPathComponent(path)

        do {
            try FileManager.default.removeItem(at: fileURL)
            log("Deleted file: \(path)")

            // Clean up empty parent directories
            var parentURL = fileURL.deletingLastPathComponent()
            while parentURL.path != rootPath.path {
                let contents = try? FileManager.default.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
                if contents?.isEmpty == true {
                    try? FileManager.default.removeItem(at: parentURL)
                    parentURL = parentURL.deletingLastPathComponent()
                } else {
                    break
                }
            }
        } catch {
            log("Failed to delete file \(path): \(error)")
        }
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
        let connectionId = ObjectIdentifier(connection)

        // Get current buffer
        bufferLock.lock()
        var buffer = connectionBuffers[connectionId] ?? Data()
        bufferLock.unlock()

        // Try to parse a complete message from buffer
        if let message = tryParseMessage(from: &buffer) {
            // Save remaining buffer
            bufferLock.lock()
            connectionBuffers[connectionId] = buffer
            bufferLock.unlock()
            completion(.success(message))
            return
        }

        // Need more data
        receiveMoreData(connection, buffer: buffer, completion: completion)
    }

    private func tryParseMessage(from buffer: inout Data) -> SyncMessage? {
        // Find header end (newline)
        guard let headerEnd = buffer.firstIndex(of: 0x0A) else {
            return nil
        }

        let headerData = buffer[..<headerEnd]
        guard let header = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let type = SyncMessageType(rawValue: String(parts[0])),
              let length = Int(parts[1]) else {
            return nil
        }

        let payloadStart = buffer.index(after: headerEnd)
        let availablePayload = buffer.count - (payloadStart - buffer.startIndex)

        guard availablePayload >= length else {
            return nil  // Not enough payload data yet
        }

        // Extract payload
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])

        // Remove consumed data from buffer
        buffer = Data(buffer[payloadEnd...])

        return SyncMessage(type: type, payload: payload)
    }

    private func receiveMoreData(_ connection: NWConnection, buffer: Data, completion: @escaping (Result<SyncMessage, Error>) -> Void) {
        let connectionId = ObjectIdentifier(connection)

        // Read more data (up to 64KB at a time for efficiency)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data, !data.isEmpty else {
                completion(.failure(SyncProtocolError.incompletePayload))
                return
            }

            // Append to buffer
            var newBuffer = buffer
            newBuffer.append(data)

            // Try to parse again
            if let message = self.tryParseMessage(from: &newBuffer) {
                // Save remaining buffer
                self.bufferLock.lock()
                self.connectionBuffers[connectionId] = newBuffer
                self.bufferLock.unlock()
                completion(.success(message))
            } else {
                // Still need more data
                self.receiveMoreData(connection, buffer: newBuffer, completion: completion)
            }
        }
    }

    private func printServerInfo() {
        log("Server listening on port \(port)")
        log("Serving: \(rootPath.path)")
        log("")
        log("Connect using:")
        for ip in getLocalIPAddresses() {
            log("  diffa push <local-dir> \(ip):\(port)")
            log("  diffa pull <local-dir> \(ip):\(port)")
        }
        log("")
    }

    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return ["localhost"]
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {  // IPv4
                let name = String(cString: interface.ifa_name)
                // Skip loopback
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(cString: hostname)
                        if !address.isEmpty && !addresses.contains(address) {
                            addresses.append(address)
                        }
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        return addresses.isEmpty ? ["localhost"] : addresses
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)"
        onLog?(logLine)
        print(logLine)
    }
}
