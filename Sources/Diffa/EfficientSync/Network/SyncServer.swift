import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#else
import Glibc
#endif

/// TCP server for EfficientSync daemon using cross-platform sockets
///
/// **Usage:**
/// ```swift
/// let server = SyncServer(path: URL(fileURLWithPath: "/data"), port: 8080)
/// try await server.start()
/// // Server runs until stopped
/// server.stop()
/// ```
public final class SyncServer {
    private let rootPath: URL
    private let port: UInt16
    private var listenerFd: SocketDescriptor = invalidSocket
    private var isRunning = false

    /// Shutdown pipe: used by stop() to wake the accept loop
    private var shutdownPipe: ShutdownPipe?

    /// Tracked client file descriptors for clean shutdown
    private var clientFds: Set<SocketDescriptor> = []
    private let clientFdsLock = NSLock()

    /// Active client handler tracking
    private let clientGroup = DispatchGroup()

    /// Per-connection receive buffers
    private var connectionBuffers: [SocketDescriptor: Data] = [:]
    private let bufferLock = NSLock()

    /// Callback for logging
    public var onLog: ((String) -> Void)?

    /// Normalized root path for containment checks (symlinks resolved, computed once)
    private let normalizedRootPath: String

    public init(path: URL, port: UInt16) {
        self.rootPath = path
        self.port = port
        self.normalizedRootPath = path.resolvingSymlinksInPath().standardized.path
    }

    /// Start server (blocking)
    public func start() throws {
        try startAsync()
        log("Press Ctrl+C to stop")
        dispatchMain()
    }

    /// Start server (non-blocking, for testing)
    public func startAsync() throws {
        platformSocketInit()

        // Create shutdown pipe
        guard let pipe = ShutdownPipe.create() else {
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }
        shutdownPipe = pipe

        // Create listener socket
        listenerFd = platformCreateTCPSocket()
        guard platformIsValidSocket(listenerFd) else {
            shutdownPipe?.close()
            shutdownPipe = nil
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }

        // Set SO_REUSEADDR
        platformSetReuseAddr(listenerFd)

        // Bind
        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = port.bigEndian
        #if os(Windows)
        addr.sin_addr.S_un.S_addr = INADDR_ANY.bigEndian
        #else
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        #endif

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                #if os(Windows)
                bind(listenerFd, sockaddrPtr, Int32(MemoryLayout<sockaddr_in>.size))
                #else
                bind(listenerFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }

        guard bindResult == 0 else {
            platformClose(listenerFd)
            shutdownPipe?.close()
            shutdownPipe = nil
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }

        // Listen
        guard listen(listenerFd, 5) == 0 else {
            platformClose(listenerFd)
            shutdownPipe?.close()
            shutdownPipe = nil
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }

        isRunning = true
        printServerInfo()

        // Accept loop on background thread
        DispatchQueue.global().async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Stop server
    public func stop() {
        isRunning = false

        // Wake accept loop via shutdown pipe
        shutdownPipe?.signal()

        // Close all tracked client fds to interrupt handlers
        clientFdsLock.lock()
        let fds = clientFds
        clientFdsLock.unlock()
        for fd in fds {
            platformClose(fd)
        }

        // Close listener
        if platformIsValidSocket(listenerFd) {
            platformClose(listenerFd)
            listenerFd = invalidSocket
        }

        // Wait for active handlers to finish
        clientGroup.wait()

        shutdownPipe?.close()
        shutdownPipe = nil
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        guard let pipe = shutdownPipe else { return }

        while isRunning {
            // Use poll() to wait on both listener and shutdown pipe
            var fds = [
                makePollfd(fd: listenerFd, events: Int16(POLLIN)),
                makePollfd(fd: pipe.readEnd, events: Int16(POLLIN))
            ]

            let pollResult = platformPoll(&fds, 2, -1)  // Wait indefinitely
            guard pollResult > 0 else { break }

            // Check shutdown pipe
            if fds[1].revents & Int16(POLLIN) != 0 {
                break
            }

            // Check listener
            if fds[0].revents & Int16(POLLIN) != 0 {
                var clientAddr = sockaddr_in()
                #if os(Windows)
                var clientAddrLen = Int32(MemoryLayout<sockaddr_in>.size)
                #else
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif

                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        accept(listenerFd, sockaddrPtr, &clientAddrLen)
                    }
                }

                guard platformIsValidSocket(clientFd) else { continue }

                // Track client fd
                clientFdsLock.lock()
                clientFds.insert(clientFd)
                clientFdsLock.unlock()

                // Set receive timeout (30 seconds)
                platformSetSocketTimeouts(clientFd, seconds: 30)

                log("Client connected")

                // Handle on background thread
                clientGroup.enter()
                DispatchQueue.global().async { [weak self] in
                    defer {
                        self?.cleanupClient(clientFd)
                        self?.clientGroup.leave()
                    }
                    self?.processClient(clientFd)
                }
            }
        }
    }

    private func cleanupClient(_ fd: SocketDescriptor) {
        clientFdsLock.lock()
        clientFds.remove(fd)
        clientFdsLock.unlock()

        bufferLock.lock()
        connectionBuffers.removeValue(forKey: fd)
        bufferLock.unlock()

        platformClose(fd)
        log("Client disconnected")
    }

    // MARK: - Connection Handling

    private func processClient(_ fd: SocketDescriptor) {
        // Initialize buffer
        bufferLock.lock()
        connectionBuffers[fd] = Data()
        bufferLock.unlock()

        // Read HELLO message
        guard let helloMessage = try? receiveMessage(fd),
              helloMessage.type == .hello else {
            sendError(fd, "Expected HELLO")
            return
        }

        let modeString = String(data: helloMessage.payload, encoding: .utf8) ?? ""
        guard let mode = NetworkSyncMode(rawValue: modeString) else {
            sendError(fd, "Invalid mode: \(modeString)")
            return
        }

        log("Mode: \(mode.rawValue)")

        // Send OK
        sendMessage(fd, SyncMessage(type: .ok))

        // Handle sync
        handleSync(fd, mode: mode)
    }

    private func handleSync(_ fd: SocketDescriptor, mode: NetworkSyncMode) {
        // Create local snapshot
        log("Creating snapshot...")
        guard let snapshot = try? SQLiteSyncSnapshot.create(at: rootPath) else {
            sendError(fd, "Failed to create snapshot")
            return
        }

        let localItems = snapshot.allFiles().map { NetworkFileItem(from: $0) }
        log("Local files: \(localItems.count)")

        // Receive client metadata
        guard let metadataMessage = try? receiveMessage(fd),
              metadataMessage.type == .metadata else {
            sendError(fd, "Expected METADATA")
            return
        }

        let remoteItems = NetworkFileItem.decodeCSV(metadataMessage.payload)
        log("Remote files: \(remoteItems.count)")

        // Send local metadata
        let localCSV = NetworkFileItem.encodeCSV(localItems)
        sendMessage(fd, SyncMessage(type: .metadata, payload: localCSV))

        // Handle file transfers
        handleFileTransfers(fd, mode: mode, localItems: localItems, remoteItems: remoteItems, snapshot: snapshot)
    }

    private func handleFileTransfers(
        _ fd: SocketDescriptor,
        mode: NetworkSyncMode,
        localItems: [NetworkFileItem],
        remoteItems: [NetworkFileItem],
        snapshot: SQLiteSyncSnapshot
    ) {
        while isRunning {
            guard let message = try? receiveMessage(fd) else {
                log("Error reading message")
                return
            }

            switch message.type {
            case .requestFile:
                let path = String(data: message.payload, encoding: .utf8) ?? ""
                sendFile(fd, path: path)

            case .fileData:
                receiveFile(fd, data: message.payload)

            case .deleteFile:
                let path = String(data: message.payload, encoding: .utf8) ?? ""
                deleteFile(fd, path: path)

            case .copyFile:
                let payload = String(data: message.payload, encoding: .utf8) ?? ""
                let parts = payload.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 {
                    copyFile(fd, from: String(parts[0]), to: String(parts[1]))
                } else {
                    sendError(fd, "Invalid COPY payload")
                }

            case .done:
                log("Sync complete")
                sendMessage(fd, SyncMessage(type: .done))
                return

            default:
                sendError(fd, "Unexpected message: \(message.type.rawValue)")
                return
            }
        }
    }

    // MARK: - Path Validation

    /// Resolve a relative path to an absolute URL with containment validation.
    /// Internal temp paths (.diffa_temp_*) resolve to the system temp directory.
    /// All other paths resolve to rootPath and are validated for containment.
    private func resolvePath(_ relativePath: String) -> URL? {
        if relativePath.hasPrefix(".diffa_temp_") && !relativePath.contains("/") {
            return FileManager.default.temporaryDirectory.appendingPathComponent(relativePath)
        }
        return validatePath(relativePath)
    }

    /// Validate that a relative path resolves to a location within rootPath.
    ///
    /// The candidate is built against the already-normalized root so both
    /// sides of the containment check share the same basis. Resolving
    /// symlinks on the full candidate is wrong for paths that don't exist
    /// yet: Foundation strips /private (tmp, var, etc) only for existing
    /// paths, so a new file under a /private-form root would normalize
    /// differently than the root and be falsely rejected.
    ///
    /// Internal (not private) so tests can exercise it directly.
    func validatePath(_ relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativePath.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            log("Path rejected (invalid): \(relativePath)")
            return nil
        }

        let url = URL(fileURLWithPath: normalizedRootPath).appendingPathComponent(relativePath).standardized

        // Symlink-escape guard: resolve the deepest existing ancestor
        // (or the path itself, if it exists) and require containment.
        var probe = url
        while probe.path != normalizedRootPath,
              (try? FileManager.default.attributesOfItem(atPath: probe.path)) == nil {
            probe = probe.deletingLastPathComponent()
        }
        let resolved = probe.resolvingSymlinksInPath().standardized.path
        guard resolved == normalizedRootPath || resolved.hasPrefix(normalizedRootPath + "/") else {
            log("Path rejected (outside root): \(relativePath)")
            return nil
        }

        return url
    }

    private func sendFile(_ fd: SocketDescriptor, path: String) {
        guard let fileURL = validatePath(path) else {
            sendError(fd, "Invalid path: \(path)")
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            sendError(fd, "File not found: \(path)")
            return
        }

        let filePayload = FilePayload.create(path: path, data: data)

        if filePayload.isCompressed {
            let ratio = 100 - (filePayload.data.count * 100 / data.count)
            log("Sending file: \(path) (\(data.count) → \(filePayload.data.count) bytes, \(ratio)% saved)")
        } else {
            log("Sending file: \(path) (\(data.count) bytes)")
        }

        sendMessage(fd, SyncMessage(type: .fileData, payload: filePayload.encode()))
    }

    private func receiveFile(_ fd: SocketDescriptor, data: Data) {
        guard let filePayload = FilePayload.decode(data) else {
            sendError(fd, "Invalid file data")
            return
        }

        guard let fileData = filePayload.decompressedData() else {
            sendError(fd, "Failed to decompress file: \(filePayload.path)")
            return
        }

        guard let fileURL = validatePath(filePayload.path) else {
            sendError(fd, "Rejected file (invalid path): \(filePayload.path)")
            return
        }

        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try fileData.write(to: fileURL)
            if filePayload.isCompressed {
                log("Received file: \(filePayload.path) (\(filePayload.data.count) → \(fileData.count) bytes, decompressed)")
            } else {
                log("Received file: \(filePayload.path) (\(fileData.count) bytes)")
            }
        } catch {
            sendError(fd, "Failed to write file \(filePayload.path): \(error)")
        }
    }

    private func deleteFile(_ fd: SocketDescriptor, path: String) {
        guard let fileURL = resolvePath(path) else {
            sendError(fd, "Rejected delete (invalid path): \(path)")
            return
        }

        // Temp files live in system temp dir — just delete, no parent pruning
        if path.hasPrefix(".diffa_temp_") && !path.contains("/") {
            try? FileManager.default.removeItem(at: fileURL)
            log("Deleted temp: \(path)")
            return
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
            log("Deleted file: \(path)")

            var parentURL = fileURL.deletingLastPathComponent()
            while parentURL.path != normalizedRootPath {
                let contents = try? FileManager.default.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
                if contents?.isEmpty == true {
                    try? FileManager.default.removeItem(at: parentURL)
                    parentURL = parentURL.deletingLastPathComponent()
                } else {
                    break
                }
            }
        } catch {
            sendError(fd, "Failed to delete file \(path): \(error)")
        }
    }

    private func copyFile(_ fd: SocketDescriptor, from sourcePath: String, to destPath: String) {
        guard let sourceURL = resolvePath(sourcePath) else {
            sendError(fd, "Rejected copy source (invalid path): \(sourcePath)")
            return
        }
        guard let destURL = resolvePath(destPath) else {
            sendError(fd, "Rejected copy dest (invalid path): \(destPath)")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            log("Copied: \(sourcePath) → \(destPath)")
        } catch {
            sendError(fd, "Failed to copy \(sourcePath) → \(destPath): \(error)")
        }
    }

    // MARK: - Network Helpers

    private func sendMessage(_ fd: SocketDescriptor, _ message: SyncMessage) {
        let data = message.encode()
        data.withUnsafeBytes { ptr in
            var sent = 0
            let total = data.count
            while sent < total {
                let base = ptr.baseAddress!.advanced(by: sent)
                let n = platformSend(fd, base, total - sent)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    private func sendError(_ fd: SocketDescriptor, _ message: String) {
        log("Error: \(message)")
        sendMessage(fd, SyncMessage(type: .error, string: message))
    }

    private func receiveMessage(_ fd: SocketDescriptor) throws -> SyncMessage {
        bufferLock.lock()
        var buffer = connectionBuffers[fd] ?? Data()
        bufferLock.unlock()

        // Try to parse from existing buffer
        if let message = tryParseMessage(from: &buffer) {
            bufferLock.lock()
            connectionBuffers[fd] = buffer
            bufferLock.unlock()
            return message
        }

        // Read more data
        var readBuffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = platformRecv(fd, &readBuffer, readBuffer.count)

            guard n > 0 else {
                throw SyncProtocolError.incompletePayload
            }

            buffer.append(contentsOf: readBuffer[..<n])

            if let message = tryParseMessage(from: &buffer) {
                bufferLock.lock()
                connectionBuffers[fd] = buffer
                bufferLock.unlock()
                return message
            }
        }
    }

    private func tryParseMessage(from buffer: inout Data) -> SyncMessage? {
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
            return nil
        }

        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])

        buffer = Data(buffer[payloadEnd...])

        return SyncMessage(type: type, payload: payload)
    }

    // MARK: - Server Info

    private func printServerInfo() {
        log("Server listening on port \(port)")
        log("Serving: \(rootPath.path)")
        log("")
        log("Connect using:")
        for ip in platformGetLocalIPs() {
            log("  diffa push <local-dir> \(ip):\(port)")
            log("  diffa pull <local-dir> \(ip):\(port)")
        }
        log("")
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)"
        onLog?(logLine)
    }
}
