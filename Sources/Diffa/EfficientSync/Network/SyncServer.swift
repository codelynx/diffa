import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// TCP server for EfficientSync daemon using POSIX sockets
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
    private var listenerFd: Int32 = -1
    private var isRunning = false

    /// Shutdown pipe: write end used by stop() to wake the accept loop
    private var shutdownPipe: [Int32] = [-1, -1]

    /// Tracked client file descriptors for clean shutdown
    private var clientFds: Set<Int32> = []
    private let clientFdsLock = NSLock()

    /// Active client handler tracking
    private let clientGroup = DispatchGroup()

    /// Per-connection receive buffers
    private var connectionBuffers: [Int32: Data] = [:]
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
        log("Press Ctrl+C to stop")
        dispatchMain()
    }

    /// Start server (non-blocking, for testing)
    public func startAsync() throws {
        // Create shutdown pipe
        guard pipe(&shutdownPipe) == 0 else {
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }

        // Create listener socket
        listenerFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listenerFd >= 0 else {
            closeShutdownPipe()
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }

        // Set SO_REUSEADDR
        var reuseAddr: Int32 = 1
        setsockopt(listenerFd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenerFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            systemClose(listenerFd)
            closeShutdownPipe()
            throw SyncProtocolError.connectionFailed(host: "localhost", port: Int(port))
        }

        // Listen
        guard listen(listenerFd, 5) == 0 else {
            systemClose(listenerFd)
            closeShutdownPipe()
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
        var byte: UInt8 = 1
        _ = write(shutdownPipe[1], &byte, 1)

        // Close all tracked client fds to interrupt handlers
        clientFdsLock.lock()
        let fds = clientFds
        clientFdsLock.unlock()
        for fd in fds {
            systemClose(fd)
        }

        // Close listener
        if listenerFd >= 0 {
            systemClose(listenerFd)
            listenerFd = -1
        }

        // Wait for active handlers to finish
        clientGroup.wait()

        closeShutdownPipe()
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while isRunning {
            // Use poll() to wait on both listener and shutdown pipe
            var fds = [
                pollfd(fd: listenerFd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: shutdownPipe[0], events: Int16(POLLIN), revents: 0)
            ]

            let pollResult = poll(&fds, 2, -1)  // Wait indefinitely
            guard pollResult > 0 else { break }

            // Check shutdown pipe
            if fds[1].revents & Int16(POLLIN) != 0 {
                break
            }

            // Check listener
            if fds[0].revents & Int16(POLLIN) != 0 {
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        accept(listenerFd, sockaddrPtr, &clientAddrLen)
                    }
                }

                guard clientFd >= 0 else { continue }

                // Track client fd
                clientFdsLock.lock()
                clientFds.insert(clientFd)
                clientFdsLock.unlock()

                // Set receive timeout (30 seconds)
                var timeout = timeval(tv_sec: 30, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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

    private func cleanupClient(_ fd: Int32) {
        clientFdsLock.lock()
        clientFds.remove(fd)
        clientFdsLock.unlock()

        bufferLock.lock()
        connectionBuffers.removeValue(forKey: fd)
        bufferLock.unlock()

        systemClose(fd)
        log("Client disconnected")
    }

    // MARK: - Connection Handling

    private func processClient(_ fd: Int32) {
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

    private func handleSync(_ fd: Int32, mode: NetworkSyncMode) {
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
        _ fd: Int32,
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
                receiveFile(data: message.payload)

            case .deleteFile:
                let path = String(data: message.payload, encoding: .utf8) ?? ""
                deleteFile(path: path)

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

    private func sendFile(_ fd: Int32, path: String) {
        let fileURL = rootPath.appendingPathComponent(path)

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

    private func receiveFile(data: Data) {
        guard let filePayload = FilePayload.decode(data) else {
            log("Invalid file data")
            return
        }

        guard let fileData = filePayload.decompressedData() else {
            log("Failed to decompress file: \(filePayload.path)")
            return
        }

        let fileURL = rootPath.appendingPathComponent(filePayload.path)

        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

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
    }

    private func deleteFile(path: String) {
        let fileURL = rootPath.appendingPathComponent(path)

        do {
            try FileManager.default.removeItem(at: fileURL)
            log("Deleted file: \(path)")

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

    private func sendMessage(_ fd: Int32, _ message: SyncMessage) {
        let data = message.encode()
        data.withUnsafeBytes { ptr in
            var sent = 0
            let total = data.count
            while sent < total {
                let base = ptr.baseAddress!.advanced(by: sent)
                #if canImport(Darwin)
                let n = Darwin.send(fd, base, total - sent, 0)
                #else
                let n = Glibc.send(fd, base, total - sent, Int32(MSG_NOSIGNAL))
                #endif
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    private func sendError(_ fd: Int32, _ message: String) {
        log("Error: \(message)")
        sendMessage(fd, SyncMessage(type: .error, string: message))
    }

    private func receiveMessage(_ fd: Int32) throws -> SyncMessage {
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
            #if canImport(Darwin)
            let n = Darwin.recv(fd, &readBuffer, readBuffer.count, 0)
            #else
            let n = Glibc.recv(fd, &readBuffer, readBuffer.count, 0)
            #endif

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

            if addrFamily == sa_family_t(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Skip loopback (lo0 on macOS, lo on Linux)
                if name != "lo0" && name != "lo" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    if getnameinfo(interface.ifa_addr, addrLen,
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

    // MARK: - Helpers

    private func closeShutdownPipe() {
        if shutdownPipe[0] >= 0 { systemClose(shutdownPipe[0]); shutdownPipe[0] = -1 }
        if shutdownPipe[1] >= 0 { systemClose(shutdownPipe[1]); shutdownPipe[1] = -1 }
    }

    private func systemClose(_ fd: Int32) {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)"
        onLog?(logLine)
    }
}
