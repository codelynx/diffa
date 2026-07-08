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

        // Wait for server DONE, draining any ERROR messages the server
        // queued for individual operations it rejected or failed to apply.
        var serverErrors: [String] = []
        while true {
            let reply = try receiveMessageSync(fd)
            if reply.type == .done { break }
            if reply.type == .error {
                let text = String(data: reply.payload, encoding: .utf8) ?? "Unknown error"
                log("Server error: \(text)")
                serverErrors.append(text)
            } else {
                log("Warning: Expected DONE, got \(reply.type.rawValue)")
            }
        }

        if let firstError = serverErrors.first {
            let suffix = serverErrors.count > 1 ? " (+\(serverErrors.count - 1) more)" : ""
            throw SyncProtocolError.serverError(message: firstError + suffix)
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
            case copyLocal(from: String, to: String)
            case copyRemote(from: String, to: String)
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
            // Destination = remote. Build hash index from remote files.
            var remoteByHash: [String: String] = [:]
            for item in remoteItems {
                if remoteByHash[item.hash] == nil {
                    remoteByHash[item.hash] = item.path
                }
            }

            // Process source files in sorted order for deterministic behavior
            for path in localByPath.keys.sorted() {
                let localItem = localByPath[path]!
                let needsTransfer: Bool
                if let remoteItem = remoteByPath[path] {
                    needsTransfer = localItem.hash != remoteItem.hash
                } else {
                    needsTransfer = true
                }

                if needsTransfer {
                    if let source = remoteByHash[localItem.hash] {
                        operations.append(TransferOperation(action: .copyRemote(from: source, to: path)))
                    } else {
                        operations.append(TransferOperation(action: .upload(path: path)))
                    }
                    if remoteByHash[localItem.hash] == nil {
                        remoteByHash[localItem.hash] = path
                    }
                }
            }

            // Deletes last
            for path in remoteByPath.keys.sorted() {
                if localByPath[path] == nil {
                    operations.append(TransferOperation(action: .delete(path: path)))
                }
            }

        case .pull:
            // Destination = local. Build hash index from local files.
            var localByHash: [String: String] = [:]
            for item in localItems {
                if localByHash[item.hash] == nil {
                    localByHash[item.hash] = item.path
                }
            }

            // Process source files in sorted order for deterministic behavior
            for path in remoteByPath.keys.sorted() {
                let remoteItem = remoteByPath[path]!
                let needsTransfer: Bool
                if let localItem = localByPath[path] {
                    needsTransfer = remoteItem.hash != localItem.hash
                } else {
                    needsTransfer = true
                }

                if needsTransfer {
                    if let source = localByHash[remoteItem.hash] {
                        operations.append(TransferOperation(action: .copyLocal(from: source, to: path)))
                    } else {
                        operations.append(TransferOperation(action: .download(path: path)))
                    }
                    if localByHash[remoteItem.hash] == nil {
                        localByHash[remoteItem.hash] = path
                    }
                }
            }

            // Deletes last
            for path in localByPath.keys.sorted() {
                if remoteByPath[path] == nil {
                    operations.append(TransferOperation(action: .delete(path: path)))
                }
            }
        }

        // Resolve copy cycles (e.g. swap: A→B, B→A) with temp files
        operations = resolveCopyCycles(operations, mode: mode)

        return operations
    }

    /// Resolve cycles in copy operations using temp files.
    ///
    /// When copies form a cycle (e.g. swap: copy A→B and copy B→A),
    /// executing them sequentially corrupts data. Break each cycle by
    /// saving one file to a temp path first.
    ///
    /// Cycle [A→B, B→A] becomes:
    ///   copy A → .diffa_temp, copy B → A, copy .diffa_temp → B, delete .diffa_temp
    private func resolveCopyCycles(
        _ operations: [TransferOperation],
        mode: NetworkSyncMode
    ) -> [TransferOperation] {
        // Extract copy operations: dest → source
        var destToSource: [String: String] = [:]
        for op in operations {
            switch op.action {
            case .copyRemote(let from, let to), .copyLocal(let from, let to):
                destToSource[to] = from
            default:
                break
            }
        }

        // Find all cycles
        var visited = Set<String>()
        var cycles: [[String]] = []

        for dest in destToSource.keys {
            if visited.contains(dest) { continue }

            // Walk the chain: dest → source → source's dest → ...
            var chain: [String] = []
            var current: String? = dest
            var seen = Set<String>()

            while let node = current, !seen.contains(node) {
                seen.insert(node)
                chain.append(node)
                // Follow chain: source of this node may itself be a copy destination
                if let src = destToSource[node], destToSource[src] != nil {
                    current = src
                } else {
                    current = nil
                }
            }

            if let node = current, seen.contains(node) {
                // Found a cycle — extract it
                if let cycleStart = chain.firstIndex(of: node) {
                    let cycle = Array(chain[cycleStart...])
                    if cycle.count >= 2 {
                        cycles.append(cycle)
                        visited.formUnion(cycle)
                    }
                }
            }
            visited.formUnion(chain)
        }

        guard !cycles.isEmpty else { return operations }

        // Collect all cycle destinations for filtering
        var cycleDests = Set<String>()
        for cycle in cycles {
            cycleDests.formUnion(cycle)
        }

        // Rebuild operations: keep non-cycle ops, replace cycle copies with temp-based sequence
        var result: [TransferOperation] = []

        // First: emit cycle-breaking operations (must run before deletes)
        for cycle in cycles {
            let tempPath = ".diffa_temp_\(UUID().uuidString)"

            // Save first node's content to temp
            let firstDest = cycle[0]
            let firstSource = destToSource[firstDest]!

            if mode == .push {
                result.append(TransferOperation(action: .copyRemote(from: firstSource, to: tempPath)))
            } else {
                result.append(TransferOperation(action: .copyLocal(from: firstSource, to: tempPath)))
            }

            // Process cycle in reverse: each copy's source hasn't been touched yet
            // cycle = [D₁, D₂, ..., Dₙ] where copy(from: source_i, to: D_i)
            // source_i = D_{i-1} for i>1, source_1 = Dₙ... no wait.
            // destToSource[D₁] = S₁, destToSource[D₂] = S₂, etc.
            // The cycle means S₁ = D_k for some k.
            // For swap: D₁=hello.txt, S₁=world.txt, D₂=world.txt, S₂=hello.txt
            // cycle = [hello.txt, world.txt]
            // We saved S₁ (world.txt) to temp.
            // Now copy S₂ (hello.txt) → D₂ (world.txt) — hello.txt hasn't been touched
            // Then copy temp → D₁ (hello.txt)

            // Process forward: cycle[i]'s source is cycle[i+1], which hasn't been written yet
            for i in 1..<cycle.count {
                let dest = cycle[i]
                let source = destToSource[dest]!
                if mode == .push {
                    result.append(TransferOperation(action: .copyRemote(from: source, to: dest)))
                } else {
                    result.append(TransferOperation(action: .copyLocal(from: source, to: dest)))
                }
            }

            // Copy temp → first destination
            if mode == .push {
                result.append(TransferOperation(action: .copyRemote(from: tempPath, to: firstDest)))
                result.append(TransferOperation(action: .delete(path: tempPath)))
            } else {
                result.append(TransferOperation(action: .copyLocal(from: tempPath, to: firstDest)))
                result.append(TransferOperation(action: .delete(path: tempPath)))
            }
        }

        // Then: emit non-cycle operations in original order
        for op in operations {
            switch op.action {
            case .copyRemote(_, let to), .copyLocal(_, let to):
                if !cycleDests.contains(to) {
                    result.append(op)
                }
            default:
                result.append(op)
            }
        }

        return result
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

            case .copyLocal(let from, let to):
                onProgress?(to, current, total)
                log("Copying (local): \(from) → \(to)")

                let sourceURL = resolveLocalPath(from, under: localPath)
                let destURL = resolveLocalPath(to, under: localPath)

                // Validate non-temp paths stay within sync root
                if !isTempPath(from) {
                    guard validatePath(sourceURL, under: localPath) else {
                        log("Copy rejected (invalid source): \(from)")
                        continue
                    }
                }
                if !isTempPath(to) {
                    guard validatePath(destURL, under: localPath) else {
                        log("Copy rejected (invalid dest): \(to)")
                        continue
                    }
                }

                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)

            case .copyRemote(let from, let to):
                onProgress?(to, current, total)
                log("Copying (remote): \(from) → \(to)")
                let payload = "\(from)\t\(to)"
                try sendMessageSync(fd, SyncMessage(type: .copyFile, string: payload))

            case .delete(let path):
                onProgress?(path, current, total)

                if mode == .push {
                    log("Deleting (remote): \(path)")
                    try sendMessageSync(fd, SyncMessage(type: .deleteFile, string: path))
                } else {
                    log("Deleting (local): \(path)")
                    let fileURL = resolveLocalPath(path, under: localPath)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    /// Check if a relative path is an internal temp file
    private func isTempPath(_ path: String) -> Bool {
        path.hasPrefix(".diffa_temp_") && !path.contains("/")
    }

    /// Resolve a relative path — temp paths go to system temp dir, others to sync root
    private func resolveLocalPath(_ relativePath: String, under root: URL) -> URL {
        if isTempPath(relativePath) {
            return FileManager.default.temporaryDirectory.appendingPathComponent(relativePath)
        }
        return root.appendingPathComponent(relativePath)
    }

    /// Validate that a URL stays within the sync root (resolves symlinks)
    private func validatePath(_ url: URL, under root: URL) -> Bool {
        let normalized = url.resolvingSymlinksInPath().standardized.path
        let rootPath = root.resolvingSymlinksInPath().standardized.path
        return normalized == rootPath || normalized.hasPrefix(rootPath + "/")
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
